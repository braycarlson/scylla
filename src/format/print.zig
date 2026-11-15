const std = @import("std");
const assert = std.debug.assert;
const bounded = @import("../stdx/bounded.zig");
const ir = @import("ir.zig");
const scan = @import("../text/scan.zig");
const ArrayType = bounded.ArrayType;
const Buffer = bounded.Buffer;
const Document = ir.Document;
const Element = ir.Element;
const Source = ir.Source;
const Span = bounded.Span;
const Text = ir.Text;
const choice_depth_max = ir.choice_depth_max;
const fill_softs = ir.fill_softs;
const group_depth_max = ir.group_depth_max;
const indent_depth_max = ir.indent_depth_max;
const point_columns = @import("walk.zig").point_columns;

pub const Options = struct {
    indent_width: u32,
    line_width: u32,
    tabs: bool,

    pub const default: Options = .{
        .indent_width = 4,
        .line_width = 88,
        .tabs = false,
    };
};

pub const Shadow = struct {
    failed: bool,
    index_next: u32,
    out: Buffer,
    state: State,

    pub fn init(gpa: std.mem.Allocator, capacity: u32) std.mem.Allocator.Error!Shadow {
        assert(capacity > 0);

        const out = try Buffer.init(gpa, capacity);

        assert(out.empty());
        assert(out.capacity() == capacity);

        return .{
            .failed = false,
            .index_next = 0,
            .out = out,
            .state = .initial,
        };
    }

    pub fn deinit(shadow: *Shadow, gpa: std.mem.Allocator) void {
        assert(shadow.state.depth <= group_depth_max);
        assert(shadow.state.owes <= indent_depth_max);

        shadow.out.deinit(gpa);
        shadow.* = undefined;
    }

    pub fn clear(shadow: *Shadow) void {
        shadow.failed = false;
        shadow.index_next = 0;

        shadow.out.clear();
        shadow.state = .initial;

        assert(shadow.out.empty());
        assert(shadow.state.printer.line_start);
    }

    pub fn advance(
        shadow: *Shadow,
        document: *const Document,
        source: []const u8,
        arena: []const u8,
        options: Options,
        stop: u32,
    ) error{Overflow}!void {
        assert(stop <= document.count());
        assert(shadow.state.depth <= group_depth_max);

        if (shadow.failed) return error.Overflow;
        assert(source.len <= std.math.maxInt(u32));
        assert(arena.len <= std.math.maxInt(u32));
        assert(options.line_width > 0);

        errdefer shadow.failed = true;

        while (shadow.index_next < stop) {
            const position = shadow.index_next;

            try step(&shadow.state, document, source, arena, options, &shadow.out, position);

            shadow.index_next += 1;
        }

        const bytes = shadow.out.const_slice();

        if (std.mem.findScalarLast(u8, bytes, '\n')) |at| {
            shadow.out.splice(.between(0, @intCast(at + 1)), &.{}) catch unreachable;
        }

        assert(std.mem.findScalar(u8, shadow.out.const_slice(), '\n') == null);
    }

    pub fn index(shadow: *const Shadow) u32 {
        assert(shadow.state.depth <= group_depth_max);
        assert(shadow.state.choices <= choice_depth_max);

        return shadow.index_next;
    }

    pub fn indent(shadow: *const Shadow) u32 {
        assert(shadow.state.printer.indent <= indent_depth_max);
        assert(shadow.state.owes <= indent_depth_max);

        return shadow.state.printer.indent;
    }

    pub fn owed_broken(shadow: *const Shadow, count: u32) u32 {
        assert(shadow.state.owes <= indent_depth_max);
        assert(count < std.math.maxInt(u32));

        const held = @min(count, shadow.state.owes);
        var broken_count: u32 = 0;

        for (shadow.state.owing[0..held]) |broken| {
            if (broken) broken_count += 1;
        }

        assert(broken_count <= held);

        return broken_count;
    }

    pub fn inset_after(shadow: *const Shadow, opened: u32) ?u32 {
        assert(shadow.state.owes <= indent_depth_max);

        const owes = shadow.state.owes_at[0..shadow.state.owes];

        for (owes, 0..) |owe, found| {
            if (owe.at < opened) continue;
            if (!shadow.state.owing[found]) return null;

            assert(owe.inset > 0);

            return owe.inset;
        }

        return null;
    }
};

const Width = union(enum) {
    broken,
    flat: u32,
};

const Held = enum {
    joined,
    wide,
};

const Columns = struct {
    leading: u32,
    trailing: u32,
    broken: bool,

    const none: Columns = .{ .leading = 0, .trailing = 0, .broken = false };
};

const Decoded = struct {
    code: u32,
    step: u32,
};

const Hug = struct {
    at: u32,
    heads: bool,
};

const HugWidth = struct {
    width: Width,
    hugs: bool,
};

const Lead = struct {
    width: u32,
    mask: u8,
};

const Owe = struct {
    at: u32,
    inset: u32,
};

const ReachWalk = struct {
    arrow: bool,
    blank: bool,
    depth: u32,
    index: u32,
    reached: bool,
    width: u32,
};

const SpanningWalk = struct {
    blank: bool,
    depth: u32,
    glued: bool,
    index: u32,
    width: u32,
};

const TypeWalk = struct {
    blank: bool,
    depth: u32,
    index: u32,
    nested: u32,
    width: u32,
};

const WidthWalk = struct {
    blank: bool,
    closed: bool,
    depth: u32,
    index: u32,
    nested: u32,
    nesting: u32,
    skipping: bool,
    width: u32,
};

const Printer = struct {
    column: u32,
    columns: u32,
    indent: u32,
    line_commented: bool,
    line_start: bool,
    line_verbatim: bool,
    lines: u32,
    pending_space: bool,
    suffixed: u32,
    suffixes: [suffix_count_max]Text,

    const initial: Printer = .{
        .column = 0,
        .columns = 0,
        .indent = 0,
        .line_commented = false,
        .line_start = true,
        .line_verbatim = false,
        .lines = 0,
        .pending_space = false,
        .suffixed = 0,
        .suffixes = @splat(.{ .source = .literal, .span = .empty }),
    };

    fn leading(printer: *const Printer, options: Options) u32 {
        assert(printer.indent <= indent_depth_max);
        assert(printer.columns <= indent_columns_max);
        assert(options.line_width > 0);

        return printer.indent * options.indent_width + printer.columns;
    }

    fn column_next(printer: *const Printer, options: Options, gap: u32) u32 {
        assert(gap <= 1);
        assert(options.line_width > 0);

        if (printer.line_start) {
            assert(printer.column == 0);

            return printer.leading(options);
        }

        assert(printer.column + gap < std.math.maxInt(u32));

        return printer.column + gap;
    }

    fn aligning(printer: *Printer, out: *Buffer) error{Overflow}!void {
        assert(printer.columns <= indent_columns_max);
        assert(printer.line_start);

        var columns_written: u32 = 0;

        while (columns_written < printer.columns) {
            const chunk = @min(printer.columns - columns_written, @as(u32, spaces.len));

            try out.push(spaces[0..chunk]);

            columns_written += chunk;
        }

        printer.column += printer.columns;
    }

    fn indentation(printer: *Printer, out: *Buffer, options: Options) error{Overflow}!void {
        assert(printer.line_start);
        assert(printer.column == 0);
        assert(options.line_width > 0);

        const flush_left = printer.indent == 0 and printer.columns == 0;
        if (flush_left) return;

        if (options.tabs) {
            for (0..printer.indent) |_| {
                try out.push("\t");
            }

            printer.column = printer.indent * options.indent_width;

            if (printer.columns == 0) return;
            return printer.aligning(out);
        }

        const width = printer.leading(options);

        assert(width <= indent_columns_max);

        var columns_written: u32 = 0;

        while (columns_written < width) {
            const chunk = @min(width - columns_written, @as(u32, spaces.len));

            try out.push(spaces[0..chunk]);

            columns_written += chunk;
        }

        assert(columns_written == width);

        printer.column = width;
    }

    fn lead(printer: *Printer, out: *Buffer, options: Options) error{Overflow}!void {
        assert(options.line_width > 0);

        defer assert(!printer.pending_space);

        if (printer.line_start) {
            printer.pending_space = false;

            return printer.indentation(out, options);
        }

        if (printer.pending_space) {
            printer.pending_space = false;

            try out.push(spaces[0..1]);

            printer.column += 1;
        }

        assert(!printer.line_start);
    }

    fn @"defer"(printer: *Printer, held: Source, span: Span) bool {
        assert(printer.suffixed <= suffix_count_max);
        assert(!printer.line_start);

        if (printer.suffixed == suffix_count_max) return false;

        printer.suffixes[printer.suffixed] = .{ .source = held, .span = span };
        printer.suffixed += 1;
        printer.pending_space = false;

        return true;
    }

    fn flush(printer: *Printer, held: *const Measure, out: *Buffer) error{Overflow}!void {
        assert(printer.suffixed <= suffix_count_max);

        for (printer.suffixes[0..printer.suffixed]) |suffix| {
            const bytes = span_bytes(
                held.document,
                held.source,
                held.arena,
                suffix.source,
                suffix.span,
            );

            assert(std.mem.startsWith(u8, bytes, "//"));

            try out.push(spaces[0..1]);
            try out.push(bytes);

            printer.line_verbatim = true;
        }

        printer.suffixed = 0;
    }

    fn newline(printer: *Printer, held: *const Measure, out: *Buffer) error{Overflow}!void {
        try printer.flush(held, out);
        try printer.broke(out);
    }

    fn broke(printer: *Printer, out: *Buffer) error{Overflow}!void {
        assert(printer.suffixed == 0);
        assert(line_ends_clean(out, printer.line_verbatim));

        printer.pending_space = false;
        printer.line_commented = false;

        try out.push("\n");

        printer.column = 0;
        printer.line_start = true;
        printer.lines += 1;
        printer.line_verbatim = false;
    }

    fn text(
        printer: *Printer,
        out: *Buffer,
        bytes: []const u8,
        options: Options,
    ) error{Overflow}!void {
        assert(bytes.len <= std.math.maxInt(u32));
        assert(options.line_width > 0);

        if (bytes.len == 0) return;

        if (printer.line_commented) try printer.broke(out);

        try printer.lead(out, options);
        try out.push(bytes);

        printer.line_start = false;

        const found = columns_of(bytes, options.indent_width);

        if (found.broken) {
            printer.column = found.trailing;
            printer.line_start = bytes[bytes.len - 1] == '\n';

            return;
        }

        assert(found.leading == found.trailing);
        assert(!printer.pending_space);

        printer.column += found.trailing;
    }

    fn starred(
        printer: *Printer,
        out: *Buffer,
        bytes: []const u8,
        options: Options,
    ) error{Overflow}!void {
        assert(bytes.len <= std.math.maxInt(u32));
        assert(options.line_width > 0);

        var offset: usize = 0;

        while (offset < bytes.len) {
            const stop = std.mem.findScalarPos(u8, bytes, offset, '\n') orelse bytes.len;
            const line = scan.trim_ascii(bytes[offset..stop]);

            assert(stop <= bytes.len);

            if (offset == 0) {
                try printer.text(out, line, options);

                offset = stop + 1;

                continue;
            }

            try out.push("\n");

            printer.column = 0;
            printer.line_start = true;

            try printer.indentation(out, options);
            try out.push(spaces[0..1]);

            printer.column += 1;
            printer.line_start = false;

            try out.push(line);

            printer.column += columns_of(line, options.indent_width).trailing;
            offset = stop + 1;
        }

        assert(offset >= bytes.len);

        printer.line_verbatim = true;
        printer.line_start = false;
    }

    fn verbatim(
        printer: *Printer,
        out: *Buffer,
        bytes: []const u8,
        options: Options,
    ) error{Overflow}!void {
        assert(printer.suffixed <= suffix_count_max);
        assert(printer.indent <= indent_depth_max);
        assert(bytes.len <= std.math.maxInt(u32));
        assert(options.line_width > 0);

        try printer.text(out, bytes, options);

        printer.line_verbatim = true;
    }
};

const State = struct {
    breaks: [group_depth_max + 1]bool,
    choices: u32,
    depth: u32,
    filled: [group_depth_max + 1]?u32,
    hugged: bool,
    hugs: [group_depth_max + 1]bool,
    itemed: [group_depth_max + 1]u32,
    losing: bool,
    losses_depth: u32,
    marks: [group_depth_max + 1]bool,
    nested: u32,
    owes: u32,
    owes_at: [indent_depth_max]Owe,
    owing: [indent_depth_max]bool,
    owning: [indent_depth_max]u32,
    owns: u32,
    printer: Printer,
    seen: [choice_depth_max]u32,
    skipping: bool,
    softs: [group_depth_max + 1]bool,
    taken: [choice_depth_max]u32,

    const initial: State = .{
        .breaks = @splat(true),
        .choices = 0,
        .depth = 0,
        .filled = @splat(null),
        .hugged = false,
        .hugs = @splat(false),
        .itemed = @splat(0),
        .losing = false,
        .losses_depth = 0,
        .marks = @splat(false),
        .nested = 0,
        .owes = 0,
        .owes_at = @splat(.{ .at = 0, .inset = 0 }),
        .owing = @splat(false),
        .owning = @splat(0),
        .owns = 0,
        .printer = .initial,
        .seen = @splat(0),
        .skipping = false,
        .softs = @splat(false),
        .taken = @splat(0),
    };

    fn losses(state: *State, element: Element) bool {
        assert(state.choices <= choice_depth_max);
        if (element == .choice_close) assert(state.choices > 0);

        if (!state.losing) return false;

        assert(state.choices > 0);

        switch (element) {
            .choice => state.losses_depth += 1,
            .choice_close => {
                if (state.losses_depth > 0) {
                    state.losses_depth -= 1;

                    return true;
                }

                state.losing = false;
                state.choices -= 1;
            },
            .variant => {
                if (state.losses_depth > 0) return true;

                const held = state.choices - 1;

                state.seen[held] += 1;
                state.losing = state.seen[held] != state.taken[held];
            },
            else => {},
        }

        return true;
    }

    fn chose(
        state: *State,
        held: *const Measure,
        options: Options,
        index: u32,
        count: u32,
    ) error{Overflow}!void {
        assert(state.choices <= choice_depth_max);
        assert(count > 1);

        if (state.choices == choice_depth_max) return error.Overflow;
        assert(index < std.math.maxInt(u32));
        assert(options.line_width > 0);

        const gap = @intFromBool(state.printer.pending_space);
        const column = state.printer.column_next(options, gap);
        const budget = options.line_width -| column;
        const blank = state.printer.line_start or state.printer.pending_space;
        const taken = fitting(held, index, count, budget, blank);

        assert(taken < count);

        state.seen[state.choices] = 0;
        state.taken[state.choices] = taken;
        state.choices += 1;
        state.losing = taken != 0;

        if (state.losing) state.losses_depth = 0;
    }

    fn variant(state: *State) void {
        assert(state.choices > 0);
        assert(!state.losing);

        state.losing = true;
        state.losses_depth = 0;
    }

    fn chosen(state: *State) void {
        assert(state.choices > 0);
        assert(!state.losing);

        state.choices -= 1;
    }

    fn skipped(state: *State, element: Element) bool {
        assert(state.depth <= group_depth_max);
        if (element == .group_close) assert(!state.skipping or state.depth > 0);

        if (!state.skipping) return false;

        if (element == .group_open) {
            state.nested += 1;

            return true;
        }

        if (element != .group_close) return true;

        if (state.nested > 0) {
            state.nested -= 1;

            return true;
        }

        assert(state.depth > 0);

        state.depth -= 1;
        state.skipping = false;

        return true;
    }

    fn broken(state: *const State) bool {
        assert(state.depth <= group_depth_max);
        assert(state.choices <= choice_depth_max);

        return state.breaks[state.depth];
    }

    fn marked(state: *const State) bool {
        assert(state.depth <= group_depth_max);
        assert(state.owns <= indent_depth_max);

        return state.marks[state.depth];
    }

    fn close(state: *State) void {
        assert(state.depth > 0);
        assert(state.depth <= group_depth_max);

        state.depth -= 1;
    }

    fn dedent(state: *State) void {
        assert(state.printer.indent > 0);
        assert(state.printer.indent <= indent_depth_max);

        state.printer.indent -= 1;
    }

    fn indent(state: *State) void {
        assert(state.printer.indent < indent_depth_max);
        assert(state.owes <= indent_depth_max);

        state.printer.indent += 1;
    }

    fn aligns(state: *State) error{Overflow}!void {
        assert(state.owns <= indent_depth_max);

        if (state.owns == indent_depth_max) return error.Overflow;

        const held = state.broken() or (hug_aligns and state.hugs[state.depth]);
        const columns: u32 = if (held) align_columns else 0;

        try state.owned(columns);
    }

    fn aligns_column(state: *State, options: Options) error{Overflow}!void {
        assert(state.owns <= indent_depth_max);

        if (state.owns == indent_depth_max) return error.Overflow;
        assert(options.line_width > 0);

        const leading = state.printer.leading(options);
        const column = if (state.printer.line_start) leading else state.printer.column;

        try state.owned(column -| leading);
    }

    fn owned(state: *State, columns: u32) error{Overflow}!void {
        assert(state.owns < indent_depth_max);
        assert(columns <= std.math.maxInt(u32) - state.printer.columns);

        if (state.printer.columns + columns > indent_columns_max) return error.Overflow;

        state.owning[state.owns] = columns;
        state.owns += 1;
        state.printer.columns += columns;

        assert(state.printer.columns <= indent_columns_max);
    }

    fn aligned(state: *State) void {
        assert(state.owns > 0);
        assert(state.printer.columns <= indent_columns_max);

        state.owns -= 1;

        const columns = state.owning[state.owns];

        assert(state.printer.columns >= columns);

        state.printer.columns -= columns;
    }

    fn owe(state: *State, index: u32) error{Overflow}!void {
        assert(state.owes <= indent_depth_max);

        if (state.owes == indent_depth_max) return error.Overflow;
        assert(index < std.math.maxInt(u32));

        const held = state.broken();
        const inset = state.printer.indent + @intFromBool(held);

        state.owing[state.owes] = held;
        state.owes_at[state.owes] = .{ .at = index, .inset = inset };
        state.owes += 1;

        if (held) state.indent();

        assert(state.printer.indent == inset);
    }

    fn owed(state: *State) void {
        assert(state.owes > 0);
        assert(state.owes <= indent_depth_max);

        state.owes -= 1;

        if (state.owing[state.owes]) state.dedent();
    }

    fn line(
        state: *State,
        held: *const Measure,
        options: Options,
        out: *Buffer,
        index: u32,
    ) error{Overflow}!void {
        assert(index < held.document.count());
        assert(state.depth <= group_depth_max);
        assert(options.line_width > 0);

        if (!state.broken()) return state.space();

        if (state.filled[state.depth]) |filled| {
            if (!state.item_broke()) {
                const column = state.printer.column_next(options, 1);
                const budget = options.line_width -| column -| filled;
                if (fill_width(held, index + 1, budget) <= budget) return state.space();
            }
        }

        try state.printer.newline(held, out);

        state.itemizes();
    }

    fn open(state: *State, held: *const Measure, options: Options, index: u32) void {
        assert(options.line_width > 0);

        const elements = held.document.elements_slice();
        const marking = state.hugged;

        assert(state.depth < group_depth_max);
        assert(elements[index] == .group_open);

        state.hugged = false;

        const gap = @intFromBool(state.printer.pending_space);
        const column = state.printer.column_next(options, gap);
        const budget = options.line_width -| column;
        const blank = state.printer.line_start or state.printer.pending_space;
        const found = open_width(held, index, budget, blank, state.broken());
        const newed = state.depth > 0 and element_is(elements, index + 1, .reach_new);
        const inherits = !state.broken() and !state.hugs[state.depth];
        const flat = !marking and (inherits or (!newed and found.width == .flat));
        const fills = open_fills(elements, index);
        const softs = if (fills) |reserve| (reserve & fill_softs) != 0 else false;

        state.depth += 1;
        state.breaks[state.depth] = !flat;
        state.filled[state.depth] = if (fills) |reserve| reserve & ~fill_softs else null;
        state.softs[state.depth] = softs;
        state.itemed[state.depth] = state.printer.lines;
        state.hugs[state.depth] = found.hugs;
        state.marks[state.depth] = marking;

        if (softs) assert(state.filled[state.depth] != null);
    }

    fn fills_flat(state: *const State, held: *const Measure, options: Options, index: u32) bool {
        assert(index < held.document.count());
        assert(state.depth <= group_depth_max);

        if (!jsx_fill_spaces) return false;
        if (!state.softs[state.depth]) return false;
        if (state.item_broke()) return false;
        assert(options.line_width > 0);

        const elements = held.document.elements_slice();
        if (!element_is(elements, index + 1, .if_flat)) return false;
        if (!element_is(elements, index + 2, .soft_line)) return false;

        const filled = state.filled[state.depth];

        assert(filled != null);

        const column = state.printer.column_next(options, 0);
        const budget = options.line_width -| column -| filled.? -| 1;

        return fill_width(held, index + 3, budget) <= budget;
    }

    fn soft(
        state: *State,
        held: *const Measure,
        options: Options,
        out: *Buffer,
        index: u32,
    ) error{Overflow}!void {
        assert(index < held.document.count());
        assert(state.depth <= group_depth_max);
        assert(options.line_width > 0);

        if (!state.broken()) return;

        const fills = state.softs[state.depth] and !state.item_broke();

        if (fills) {
            const filled = state.filled[state.depth];

            assert(filled != null);

            const column = state.printer.column_next(options, 0);
            const budget = options.line_width -| column -| filled.?;
            if (fill_width(held, index + 1, budget) <= budget) return;
        }

        try state.printer.newline(held, out);

        state.itemizes();
    }

    fn item_broke(state: *const State) bool {
        assert(state.depth <= group_depth_max);
        assert(state.itemed[state.depth] <= state.printer.lines);

        const lines_moved = state.printer.lines != state.itemed[state.depth];
        return fill_item_breaks and state.softs[state.depth] and lines_moved;
    }

    fn itemizes(state: *State) void {
        assert(state.depth <= group_depth_max);
        assert(state.itemed[state.depth] <= state.printer.lines);

        state.itemed[state.depth] = state.printer.lines;
    }

    fn space(state: *State) void {
        assert(state.depth <= group_depth_max);

        if (state.printer.line_start) assert(state.printer.column == 0);

        state.printer.pending_space = !state.printer.line_start;
    }
};

const Measure = struct {
    arena: []const u8,
    document: *const Document,
    source: []const u8,
    tab: u32,

    fn reads(measure: *const Measure, element: Element) bool {
        if (element == .void) return true;

        const text: Text = switch (element) {
            .hugging, .if_broken, .if_flat => |span| .{ .source = .literal, .span = span },
            .joined, .verbatim_arena => |span| .{ .source = .arena, .span = span },
            .text => |held| held,
            .chunk, .starred, .verbatim => |span| .{ .source = .document, .span = span },
            else => return true,
        };

        return switch (text.source) {
            .arena => text.span.end() <= measure.arena.len,
            .document => text.span.end() <= measure.source.len,
            .literal => text.span.length == 0 or
                text.span.offset < measure.document.literals.count(),
        };
    }

    fn columns(measure: *const Measure, element: Element) Columns {
        assert(measure.reads(element));

        const text: Text = switch (element) {
            .if_broken, .if_flat => |span| .{ .source = .literal, .span = span },
            .joined, .verbatim_arena => |span| .{ .source = .arena, .span = span },
            .text => |held| held,
            .chunk, .starred, .verbatim => |span| .{ .source = .document, .span = span },
            else => return .none,
        };

        const bytes = span_bytes(
            measure.document,
            measure.source,
            measure.arena,
            text.source,
            text.span,
        );

        assert(bytes.len == text.span.length);

        const chunked = chunk_columns and (element == .chunk or element == .starred);
        const suffixed = line_suffixes and measure.document.suffixed;
        const commented = suffixed and std.mem.startsWith(u8, bytes, "//") and !chunked;
        if (commented) return .none;

        const found = columns_of(bytes, measure.tab);

        if (!found.broken) assert(found.leading == found.trailing);

        return found;
    }

    fn glues(measure: *const Measure, from: u32, depth: u32) bool {
        assert(from < std.math.maxInt(u32));
        assert(depth > 0);

        const elements = measure.document.elements_slice();
        const count: u32 = @intCast(elements.len);
        var held = depth;
        var index = from;

        assert(from <= count);

        while (index < count) {
            const element = elements[index];

            index += 1;

            switch (element) {
                .blank_line, .broken, .hard_line => return false,
                .group_close => {
                    if (held <= 1) return false;

                    held -= 1;
                },
                .group_open => held += 1,
                .joined, .text, .chunk, .starred, .verbatim, .verbatim_arena => {
                    if (measure.columns(element).leading > 0) return true;
                },
                else => {},
            }
        }

        return false;
    }

    fn suffix(measure: *const Measure, element: Element) bool {
        assert(measure.reads(element));

        if (!line_suffixes) return false;
        if (!measure.document.suffixed) return false;

        const text: Text = switch (element) {
            .joined, .verbatim_arena => |span| .{ .source = .arena, .span = span },
            .text => |held| held,
            .verbatim => |span| .{ .source = .document, .span = span },
            else => return false,
        };

        const bytes = span_bytes(
            measure.document,
            measure.source,
            measure.arena,
            text.source,
            text.span,
        );

        assert(bytes.len == text.span.length);
        if (text.source == .literal) assert(element == .text);

        return std.mem.startsWith(u8, bytes, "//");
    }
};

const align_columns: u32 = 2;
const chunk_columns: bool = true;
const fill_item_breaks: bool = true;
const fill_nested_lines: bool = true;
const fill_space_ends: bool = true;
const fill_space_widths: bool = true;
const fill_spaces: bool = true;
const hug_aligns: bool = true;
const hug_heads: bool = true;
const indent_columns_max: u32 = 1 << 10;
const jsx_fill_spaces: bool = true;
const line_suffixes: bool = true;
const pragma_texts: u32 = 2;
const reach_texts: bool = true;
const spaces: [64]u8 = @splat(' ');
const suffix_count_max: u32 = 4;
const suffix_spaces: bool = true;
const tab_columns: bool = true;
const trailing_conditionals: bool = true;
const trailing_nests: bool = false;
const trailing_texts: bool = true;

comptime {
    assert(spaces.len <= indent_columns_max);
    assert(align_columns * indent_depth_max <= indent_columns_max);
    assert(suffix_count_max > 0);
}

pub fn print(
    document: *const Document,
    source: []const u8,
    arena: []const u8,
    options: Options,
    out: *Buffer,
) error{Overflow}!void {
    assert(options.indent_width > 0);
    assert(options.line_width > 0);
    assert(source.len <= std.math.maxInt(u32));
    assert(arena.len <= std.math.maxInt(u32));

    return printing(document, source, arena, options, out, null);
}

pub fn printing(
    document: *const Document,
    source: []const u8,
    arena: []const u8,
    options: Options,
    out: *Buffer,
    lines: ?*ArrayType(u32),
) error{Overflow}!void {
    assert(options.indent_width > 0);
    assert(options.line_width > 0);
    assert(source.len <= std.math.maxInt(u32));
    assert(arena.len <= std.math.maxInt(u32));
    if (lines) |mapped| assert(mapped.capacity() > 0);

    document.close();
    out.clear();

    if (lines) |mapped| mapped.clear();
    errdefer out.clear();

    const elements = document.elements_slice();
    var held: u32 = 0;
    var state: State = .initial;

    for (0..elements.len) |position| {
        const index: u32 = @intCast(position);
        const before = out.count();

        try step(&state, document, source, arena, options, out, index);

        const mapped = lines orelse continue;

        held = printing_offset(document, index, held);

        try printing_lines(out.const_slice()[before..], held, mapped);
    }

    const measure: Measure = .{
        .arena = arena,
        .document = document,
        .source = source,
        .tab = options.indent_width,
    };

    try state.printer.flush(&measure, out);

    assert(state.choices == 0);
    assert(state.depth == 0);
    assert(state.printer.indent == 0);
    assert(line_ends_clean(out, state.printer.line_verbatim));
}

fn printing_offset(document: *const Document, index: u32, held: u32) u32 {
    assert(index < document.count());

    const element = document.elements_slice()[index];
    const offset = switch (element) {
        .chunk, .starred, .verbatim => |span| span.offset,
        .text => |text| if (text.source == .document) text.span.offset else held,
        else => held,
    };

    if (element == .void) assert(offset == held);

    return offset;
}

fn printing_lines(bytes: []const u8, held: u32, mapped: *ArrayType(u32)) error{Overflow}!void {
    assert(bytes.len <= std.math.maxInt(u32));
    assert(held < std.math.maxInt(u32));

    const count = mapped.count();

    for (bytes) |byte| {
        if (byte != '\n') continue;
        if (mapped.full()) return error.Overflow;

        mapped.push(held);
    }

    assert(mapped.count() >= count);
    assert(mapped.count() - count <= bytes.len);
}

pub fn steps_blind(element: Element) bool {
    if (element == .choice) return false;

    return switch (element) {
        .choice, .choice_close, .group_open, .if_broken, .if_flat => false,
        .joined, .line, .soft_line, .variant => false,
        else => true,
    };
}

fn line_ends_clean(out: *const Buffer, verbatim: bool) bool {
    if (verbatim) return true;

    const bytes = out.const_slice();
    const start = if (std.mem.findScalarLast(u8, bytes, '\n')) |at| at + 1 else 0;
    const line = bytes[start..];

    assert(start <= bytes.len);
    assert(std.mem.findScalar(u8, line, '\n') == null);

    if (line.len == 0) return true;

    const last = line[line.len - 1];
    return last != ' ' and last != '\t';
}

fn step(
    state: *State,
    document: *const Document,
    source: []const u8,
    arena: []const u8,
    options: Options,
    out: *Buffer,
    index: u32,
) error{Overflow}!void {
    assert(source.len <= std.math.maxInt(u32));
    assert(arena.len <= std.math.maxInt(u32));
    assert(index < std.math.maxInt(u32));
    assert(options.line_width > 0);

    const element = document.elements_slice()[index];
    if (state.skipped(element)) return;
    if (state.losses(element)) return;
    if (try chosen(state, document, source, arena, options, index, element)) return;

    assert(!state.skipping);
    assert(!state.losing);

    const measure: Measure = .{
        .arena = arena,
        .document = document,
        .source = source,
        .tab = options.indent_width,
    };

    switch (element) {
        .blank_line => |lines| try blanked(state, &measure, out, lines),
        .choice, .choice_close, .variant, .broken => {},
        .dedent => state.dedent(),
        .group_close => state.close(),
        .group_open => state.open(&measure, options, index),
        .hard_line => {
            try state.printer.newline(&measure, out);

            state.itemizes();
        },
        .hugging => |span| try hugs(state, &measure, options, out, span),
        .if_broken => |span| {
            if (!state.broken()) return;
            if (state.fills_flat(&measure, options, index)) return;

            const bytes = span_bytes(document, source, arena, .literal, span);

            try state.printer.text(out, bytes, options);
        },
        .if_flat => |span| try flatted(state, &measure, options, out, span, index),
        .@"align" => try state.aligns(),
        .align_column => try state.aligns_column(options),
        .dealign => state.aligned(),
        .indent => state.indent(),
        .indent_broken => try state.owe(index),
        .dedent_broken => state.owed(),
        .filled, .pragma, .reach, .reach_arrow, .reach_new, .reach_type, .reached => {},
        .void, .wide, .heads, .hugs => {},
        .hugged => state.hugged = state.hugs[state.depth],
        .joined => |span| try joins(state, document, source, arena, options, out, span),
        .line => try state.line(&measure, options, out, index),
        .soft_line => try state.soft(&measure, options, out, index),
        .space => state.space(),
        .starred => |span| try starred(state, &measure, options, out, span),
        .chunk, .text => try texted(state, &measure, options, out, element),
        .verbatim, .verbatim_arena => try texted(state, &measure, options, out, element),
    }
}

fn chosen(
    state: *State,
    document: *const Document,
    source: []const u8,
    arena: []const u8,
    options: Options,
    index: u32,
    element: Element,
) error{Overflow}!bool {
    assert(!state.skipping);
    assert(!state.losing);
    assert(source.len <= std.math.maxInt(u32));
    assert(arena.len <= std.math.maxInt(u32));
    assert(index < document.count());
    assert(element.eql(document.elements_slice()[index]));
    assert(options.line_width > 0);

    const held: Measure = .{
        .arena = arena,
        .document = document,
        .source = source,
        .tab = options.indent_width,
    };

    switch (element) {
        .choice => |count| try state.chose(&held, options, index, count),
        .choice_close => state.chosen(),
        .variant => state.variant(),
        else => return false,
    }

    return true;
}

fn flatted(
    state: *State,
    held: *const Measure,
    options: Options,
    out: *Buffer,
    span: Span,
    index: u32,
) error{Overflow}!void {
    assert(index < held.document.count());
    assert(held.document.elements_slice()[index] == .if_flat);
    assert(span.length <= std.math.maxInt(u32) - span.offset);
    assert(options.line_width > 0);

    const filled = index > 0 and state.fills_flat(held, options, index - 1);
    const skips = state.broken() and !filled;
    if (skips) return;

    const bytes = span_bytes(held.document, held.source, held.arena, .literal, span);

    try state.printer.text(out, bytes, options);
}

fn starred(
    state: *State,
    held: *const Measure,
    options: Options,
    out: *Buffer,
    span: Span,
) error{Overflow}!void {
    assert(span.end() <= held.source.len);
    assert(!state.skipping);
    assert(options.line_width > 0);

    const bytes = span_bytes(held.document, held.source, held.arena, .document, span);

    try state.printer.starred(out, bytes, options);
}

fn texted(
    state: *State,
    held: *const Measure,
    options: Options,
    out: *Buffer,
    element: Element,
) error{Overflow}!void {
    assert(options.line_width > 0);

    assert(element == .chunk or element == .text or
        element == .verbatim or element == .verbatim_arena);

    const verbatim = element != .text;

    const text: Text = switch (element) {
        .text => |found| found,
        .chunk, .starred, .verbatim => |span| .{ .source = .document, .span = span },
        .verbatim_arena => |span| .{ .source = .arena, .span = span },
        else => unreachable,
    };

    if (state.printer.line_commented) try state.printer.newline(held, out);

    const comment = held.suffix(element);
    const suffixed = comment and !state.printer.line_start;

    if (suffixed) {
        if (state.printer.@"defer"(text.source, text.span)) return;
    }

    const bytes = span_bytes(held.document, held.source, held.arena, text.source, text.span);

    assert(bytes.len == text.span.length);

    if (verbatim) {
        try state.printer.verbatim(out, bytes, options);

        if (element == .chunk) state.printer.line_start = false;

        assert(state.printer.line_verbatim);
    } else {
        try state.printer.text(out, bytes, options);
    }

    if (comment) {
        if (!state.printer.line_start) state.printer.line_commented = true;
    }
}

fn hugs(
    state: *State,
    held: *const Measure,
    options: Options,
    out: *Buffer,
    span: Span,
) error{Overflow}!void {
    assert(state.depth <= group_depth_max);
    assert(span.length <= std.math.maxInt(u32) - span.offset);
    assert(options.line_width > 0);

    if (!state.marked()) return;

    if (span.length > 0) {
        const bytes = span_bytes(held.document, held.source, held.arena, .literal, span);

        try state.printer.text(out, bytes, options);
    }

    try state.printer.newline(held, out);

    assert(state.printer.line_start);
}

fn joins(
    state: *State,
    document: *const Document,
    source: []const u8,
    arena: []const u8,
    options: Options,
    out: *Buffer,
    span: Span,
) error{Overflow}!void {
    assert(!state.skipping);
    assert(source.len <= std.math.maxInt(u32));
    assert(arena.len <= std.math.maxInt(u32));
    assert(span.end() <= source.len);
    assert(options.line_width > 0);

    if (state.broken()) return;

    state.skipping = true;
    state.nested = 0;

    const bytes = span_bytes(document, source, arena, .arena, span);

    try state.printer.text(out, bytes, options);

    assert(state.skipping);
}

fn blanked(state: *State, held: *const Measure, out: *Buffer, lines: u32) error{Overflow}!void {
    assert(state.depth <= group_depth_max);
    assert(lines < std.math.maxInt(u32));

    try blanked_lines(&state.printer, held, out, lines);

    state.itemizes();

    if (lines > 0) assert(state.printer.line_start);
}

fn blanked_lines(
    printer: *Printer,
    held: *const Measure,
    out: *Buffer,
    lines: u32,
) error{Overflow}!void {
    assert(lines < std.math.maxInt(u32));

    if (lines == 0) return;

    const lines_before = printer.lines;

    if (!printer.line_start) try printer.newline(held, out);

    for (0..lines) |_| {
        try printer.newline(held, out);
    }

    assert(printer.line_start);
    assert(printer.lines - lines_before >= lines);
}

fn span_bytes(
    document: *const Document,
    source: []const u8,
    arena: []const u8,
    held: Source,
    span: Span,
) []const u8 {
    assert(source.len <= std.math.maxInt(u32));
    assert(arena.len <= std.math.maxInt(u32));
    if (held == .document) assert(span.end() <= source.len);
    if (held == .arena) assert(span.end() <= arena.len);

    const bytes = switch (held) {
        .arena => span.text(arena),
        .document => span.text(source),
        .literal => document.literal_of(span.offset),
    };

    assert(bytes.len == span.length);

    return bytes;
}

fn fitting(held: *const Measure, start: u32, count: u32, budget: u32, blank: bool) u32 {
    assert(start < std.math.maxInt(u32));
    assert(count < std.math.maxInt(u32));
    assert(budget < std.math.maxInt(u32));

    const elements = held.document.elements_slice();
    var index = start + 1;
    var variant: u32 = 0;

    assert(start < elements.len);
    assert(elements[start] == .choice);

    while (variant < count) : (variant += 1) {
        if (variant + 1 == count) return variant;

        if (element_is(elements, index, .group_open)) {
            if (width_of(held, index, budget, blank) == .flat) return variant;
        }

        index = group_end(elements, index + 1);

        if (!element_is(elements, index, .variant)) return variant;

        index += 1;
    }

    assert(count -| 1 < std.math.maxInt(u32));

    return count -| 1;
}

fn width_of(held: *const Measure, start: u32, budget: u32, owed: bool) Width {
    assert(budget < std.math.maxInt(u32));

    const elements = held.document.elements_slice();
    const count: u32 = @intCast(elements.len);

    assert(start < count);
    assert(elements[start] == .group_open);

    var walk: WidthWalk = .{
        .blank = owed,
        .closed = false,
        .depth = 0,
        .index = start,
        .nested = 0,
        .nesting = 0,
        .skipping = false,
        .width = 0,
    };

    for (start..count) |_| {
        if (walk.index >= count) break;

        const element = elements[walk.index];

        walk.index += 1;

        if (walk.skipping) {
            width_skipped(held, &walk);

            continue;
        }

        if (element == .variant) {
            walk.index = choice_end(elements, walk.index);

            continue;
        }

        if (walk.closed) {
            if (width_of_trailing(held, &walk, budget)) |found| return found;

            continue;
        }

        if (width_of_measured(held, &walk, budget)) |found| return found;
        if (walk.index == count) break;
    }

    if (walk.closed) return .{ .flat = walk.width };
    return .broken;
}

fn width_of_trailing(held: *const Measure, walk: *WidthWalk, budget: u32) ?Width {
    assert(walk.closed);
    assert(walk.width <= budget);
    assert(walk.index > 0);

    const element = held.document.elements_slice()[walk.index - 1];
    const spacing = element == .line or element == .space;

    switch (element) {
        .group_open => walk.nesting += 1,
        .group_close => walk.nesting -|= 1,
        else => {},
    }

    const nested = walk.nesting > 0;

    if (element == .joined) {
        walk.width += joined_first(held, walk.index, walk.blank);

        if (walk.width > budget) return .broken;
        return .{ .flat = walk.width };
    }

    const added = trailing(held, element, walk.blank, nested, walk.index) orelse {
        return .{ .flat = walk.width };
    };

    walk.width += added;
    walk.blank = spacing or (walk.blank and added == 0);

    if (walk.width > budget) return .broken;

    const texts = trailing_texts and held.columns(element).broken;
    if (texts) return .{ .flat = walk.width };
    return null;
}

fn width_of_measured(held: *const Measure, walk: *WidthWalk, budget: u32) ?Width {
    assert(!walk.closed);
    assert(!walk.skipping);
    assert(walk.index > 0);

    const element = held.document.elements_slice()[walk.index - 1];
    const spacing = element == .line or element == .space;

    if (element == .pragma) {
        walk.index = pragma_end(held.document.elements_slice(), walk.index);

        return null;
    }

    if (held.columns(element).broken) return .broken;

    const glued = held.suffix(element) and held.glues(walk.index, walk.depth);
    if (glued) return .broken;

    const added = measured(
        held,
        element,
        walk.blank,
        &walk.depth,
        &walk.closed,
        &walk.skipping,
    ) orelse return .broken;

    walk.width += added;

    const advanced = spacing or added > 0;

    if (advanced) walk.blank = spacing;

    if (walk.width > budget) return .broken;
    return null;
}

fn measured(
    held: *const Measure,
    element: Element,
    blank: bool,
    depth: *u32,
    closed: *bool,
    skipping: *bool,
) ?u32 {
    assert(depth.* <= group_depth_max);
    assert(!closed.*);
    if (element == .broken) return null;

    switch (element) {
        .blank_line => |lines| {
            if (lines > 0) return null;
            return 0;
        },
        .choice, .choice_close, .variant => return 0,
        .@"align",
        .align_column,
        .dealign,
        .dedent,
        .hugging,
        .if_broken,
        .indent,
        .soft_line,
        => return 0,
        .if_flat => return held.columns(element).leading,
        .group_close => {
            assert(depth.* > 0);

            depth.* -= 1;
            closed.* = depth.* == 0;

            return 0;
        },
        .group_open => {
            assert(depth.* < group_depth_max);

            depth.* += 1;

            return 0;
        },
        .broken, .hard_line => return null,
        .joined => {
            skipping.* = true;

            return held.columns(element).leading;
        },
        .line, .space => return @intFromBool(!blank),
        .chunk, .starred, .text, .verbatim, .verbatim_arena => {
            return held.columns(element).leading;
        },
        .dedent_broken, .filled, .heads, .hugged, .hugs, .indent_broken, .pragma, .void => {
            return 0;
        },
        .reach, .reach_arrow, .reach_new, .reach_type, .reached, .wide => return 0,
    }
}

fn pragma_end(elements: []const Element, from: u32) u32 {
    assert(elements.len <= std.math.maxInt(u32));
    assert(from < std.math.maxInt(u32));

    const count: u32 = @intCast(elements.len);
    var index = from;

    assert(from <= count);

    for (0..pragma_texts) |_| {
        if (index == count) break;
        if (elements[index] != .text) break;

        index += 1;
    }

    assert(index - from <= pragma_texts);

    return index;
}

fn width_skipped(held: *const Measure, walk: *WidthWalk) void {
    assert(walk.skipping);
    assert(walk.depth <= group_depth_max);
    assert(walk.index > 0);

    const element = held.document.elements_slice()[walk.index - 1];

    if (element == .group_open) {
        walk.nested += 1;

        return;
    }

    if (element != .group_close) return;

    if (walk.nested > 0) {
        walk.nested -= 1;

        return;
    }

    walk.skipping = false;

    walk.depth -|= 1;
    walk.closed = walk.depth == 0;
}

fn trailing(held: *const Measure, element: Element, blank: bool, nested: bool, next: u32) ?u32 {
    assert(next > 0);
    assert(next <= held.document.count());
    if (element == .blank_line) return null;

    if (suffix_spaced(held, element, next)) return 0;

    const nests = trailing_nests and nested;

    if (nests) {
        switch (element) {
            .line => return @intFromBool(!blank),
            .soft_line => return 0,
            else => {},
        }
    }

    const conditional = trailing_conditionals and !nested and element == .if_flat;
    if (conditional) return 0;

    return switch (element) {
        .blank_line, .broken, .hard_line, .line, .pragma, .soft_line => null,
        .space => @intFromBool(!blank),
        .hugging => 0,
        .if_broken, .if_flat, .joined, .text, .chunk, .starred => held.columns(element).leading,
        .verbatim_arena, .verbatim => held.columns(element).leading,
        .choice, .choice_close, .variant => null,
        .dedent,
        .group_close,
        .group_open,
        .indent,
        .@"align",
        .align_column,
        .dealign,
        .dedent_broken,
        => 0,
        .filled, .heads, .hugged, .hugs, .indent_broken, .void, .reach, .reach_arrow => 0,
        .reach_new, .reach_type, .reached, .wide => 0,
    };
}

fn suffix_spaced(held: *const Measure, element: Element, next: u32) bool {
    assert(next > 0);
    assert(next <= held.document.count());

    if (!suffix_spaces) return false;
    if (element != .space) return false;

    const found = element_at(held.document.elements_slice(), next) orelse return false;
    return held.suffix(found);
}

fn open_width(held: *const Measure, index: u32, budget: u32, blank: bool, broken: bool) HugWidth {
    assert(index < std.math.maxInt(u32));
    assert(budget < std.math.maxInt(u32));

    const elements = held.document.elements_slice();
    const next = element_at(elements, index + 1) orelse .void;

    assert(elements[index] == .group_open);

    const found: HugWidth = switch (next) {
        .joined => .{ .width = joined_width(held, index, budget, broken), .hugs = false },
        .wide => .{ .width = wide_width(held, index, budget), .hugs = false },
        .reach => .{ .width = reach_width(held, index, budget, false), .hugs = false },
        .reach_arrow => .{ .width = reach_width(held, index, budget, true), .hugs = false },
        .reach_new, .reach_type => .{ .width = type_width(held, index, budget), .hugs = false },
        else => open_width_hugged(held, index, budget, blank),
    };

    if (found.width == .flat) assert(found.width.flat <= budget);
    if (found.hugs) assert(found.width == .flat);

    return found;
}

fn open_width_hugged(held: *const Measure, index: u32, budget: u32, blank: bool) HugWidth {
    assert(budget < std.math.maxInt(u32));

    const elements = held.document.elements_slice();

    assert(index < elements.len);
    assert(elements[index] == .group_open);

    if (hugged(elements, index) != null) return hug_width(held, index, budget, blank);
    return .{ .width = width_of(held, index, budget, blank), .hugs = false };
}

fn open_fills(elements: []const Element, index: u32) ?u32 {
    assert(index < elements.len);
    assert(elements[index] == .group_open);

    const next = element_at(elements, index + 1) orelse return null;

    const reserve = switch (next) {
        .filled => |held| held,
        else => return null,
    };

    if (reserve == std.math.maxInt(u32)) return null;
    return reserve;
}

fn hug_width(held: *const Measure, start: u32, budget: u32, blank: bool) HugWidth {
    assert(start < std.math.maxInt(u32));
    assert(budget < std.math.maxInt(u32));

    const width = width_of(held, start, budget, blank);
    if (width == .flat) return .{ .width = width, .hugs = false };

    const hug = hugged(held.document.elements_slice(), start) orelse {
        return .{ .width = .broken, .hugs = false };
    };

    assert(hug.at > start);
    assert(hug.at < held.document.count());

    if (prefix_width(held, start + 1, hug.at, budget, blank)) |found| {
        return .{ .width = .{ .flat = found }, .hugs = true };
    }

    const headed = hug_heads and hug.heads;

    if (headed) {
        if (head_width(held, start + 1, hug.at, budget, blank)) |found| {
            return .{ .width = .{ .flat = found }, .hugs = true };
        }
    }

    return .{ .width = .broken, .hugs = false };
}

fn hugged(elements: []const Element, start: u32) ?Hug {
    assert(elements[start] == .group_open);

    const count: u32 = @intCast(elements.len);
    var depth: u32 = 0;
    var index = start + 1;

    assert(start < count);

    while (index < count) : (index += 1) {
        const element = elements[index];

        if (element == .group_open) depth += 1;

        if (element == .group_close) {
            if (depth == 0) return null;

            depth -= 1;
        }

        const marker = element == .heads or element == .hugged or element == .hugs;
        const found = depth == 0 and marker;
        if (found) return .{ .at = index, .heads = element == .heads };
    }

    return null;
}

fn prefix_width(held: *const Measure, from: u32, to: u32, budget: u32, owed: bool) ?u32 {
    assert(from <= to);
    assert(to <= held.document.count());
    assert(budget < std.math.maxInt(u32));

    return prefixed(held, from, to, budget, owed, false);
}

fn head_width(held: *const Measure, from: u32, to: u32, budget: u32, owed: bool) ?u32 {
    assert(from <= to);
    assert(to <= held.document.count());
    assert(budget < std.math.maxInt(u32));

    return prefixed(held, from, to, budget, owed, true);
}

fn prefixed(held: *const Measure, from: u32, to: u32, budget: u32, owed: bool, heads: bool) ?u32 {
    assert(from <= to);

    const elements = held.document.elements_slice();
    var blank = owed;
    var depth: u32 = 0;
    var index = from;
    var width: u32 = 0;

    assert(to <= elements.len);

    while (index < to) {
        const element = elements[index];
        const spacing = element == .line or element == .space;
        const before = width;

        index += 1;

        switch (element) {
            .variant => index = choice_end(elements, index),
            .blank_line, .broken, .hard_line => return null,
            .joined => {
                width += held.columns(element).leading;
                index = @min(group_end(elements, index), to);
            },
            .line, .space => {
                const headed = heads and depth > 0 and element == .line;
                if (headed) return width;

                width += @intFromBool(!blank);
            },
            .chunk, .starred, .text, .verbatim, .verbatim_arena => {
                width += text_leading(held, index, 1) orelse return null;
            },
            .soft_line => {
                const headed = heads and depth > 0;
                if (headed) return width;
            },
            .group_open => depth += 1,
            .group_close => depth -|= 1,
            .choice,
            .choice_close,
            .dedent,
            .@"align",
            .align_column,
            .dealign,
            .dedent_broken,
            .filled,
            => {},
            .heads, .hugged, .hugging, .hugs, .if_broken, .indent, .indent_broken => {},
            .pragma, .void, .reach, .reach_arrow, .reach_new, .reach_type, .reached, .wide => {},
            .if_flat => width += held.columns(element).leading,
        }

        if (width > budget) return null;

        const advanced = spacing or width > before;

        if (advanced) blank = spacing;
    }

    return width;
}

fn text_leading(held: *const Measure, index: u32, depth: u32) ?u32 {
    assert(index > 0);
    assert(depth > 0);

    const element = held.document.elements_slice()[index - 1];
    const found = held.columns(element);
    if (found.broken) return null;

    const glued = held.suffix(element) and held.glues(index, depth);
    if (glued) return null;
    return found.leading;
}

fn wide_width(held: *const Measure, start: u32, budget: u32) Width {
    assert(budget < std.math.maxInt(u32));

    const elements = held.document.elements_slice();

    assert(start < elements.len);
    assert(elements[start] == .group_open);

    const width = body_width(held, elements, start, budget) orelse return .broken;
    return spanning(held, group_end(elements, start + 1), budget, width, .wide);
}

fn body_width(held: *const Measure, elements: []const Element, start: u32, budget: u32) ?u32 {
    assert(elements[start] == .group_open);

    const count: u32 = @intCast(elements.len);
    var blank = false;
    var depth: u32 = 0;
    var index = start;
    var width: u32 = 0;

    assert(start < count);

    while (index < count) {
        if (width > budget) break;

        const element = elements[index];
        const spacing = element == .line or element == .space;
        const before = width;

        index += 1;

        switch (element) {
            .choice, .choice_close => {},
            .variant => index = choice_end(elements, index),
            .blank_line, .broken, .hard_line => return null,
            .group_close => {
                depth -= 1;

                if (depth == 0) return width;
            },
            .group_open => depth += 1,
            .joined => {
                width += held.columns(element).leading;
                index = group_end(elements, index);
            },
            .line, .space => width += @intFromBool(!blank),
            .chunk, .starred, .text, .verbatim, .verbatim_arena => {
                width += text_leading(held, index, depth) orelse return null;
            },
            .dedent,
            .@"align",
            .align_column,
            .dealign,
            .dedent_broken,
            .filled,
            .heads,
            .hugged,
            => {},
            .hugging, .hugs, .if_broken, .indent, .indent_broken, .soft_line => {},
            .pragma, .void, .reach, .reach_arrow, .reach_new, .reach_type, .reached, .wide => {},
            .if_flat => width += held.columns(element).leading,
        }

        const advanced = spacing or width > before;

        if (advanced) blank = spacing;
    }

    return null;
}

fn spanning(held: *const Measure, from: u32, budget: u32, width: u32, kind: Held) Width {
    assert(from > 0);
    assert(budget < std.math.maxInt(u32));
    assert(width < std.math.maxInt(u32));

    const elements = held.document.elements_slice();
    const count: u32 = @intCast(elements.len);

    var walk: SpanningWalk = .{
        .blank = false,
        .depth = 0,
        .glued = kind == .joined,
        .index = from,
        .width = width,
    };

    assert(from <= count);

    while (walk.index < count) {
        if (walk.width > budget) break;

        const element = elements[walk.index];
        const spacing = element == .line or element == .space;
        const before = walk.width;

        walk.index += 1;

        if (spanning_step(held, &walk, budget)) |found| return found;

        const advanced = spacing or walk.width > before;

        if (advanced) walk.blank = spacing;
    }

    return width_within(walk.width, budget);
}

fn spanning_step(held: *const Measure, walk: *SpanningWalk, budget: u32) ?Width {
    const elements = held.document.elements_slice();

    assert(walk.index > 0);
    assert(walk.width <= budget);

    const element = elements[walk.index - 1];

    switch (element) {
        .choice, .choice_close => {},
        .variant => walk.index = choice_end(elements, walk.index),
        .blank_line, .broken, .hard_line => {
            if (walk.depth > 0) return .broken;
            return .{ .flat = walk.width };
        },
        .group_close => {
            if (walk.depth == 0) return .{ .flat = walk.width };

            walk.depth -= 1;
        },
        .group_open => {
            const opener = opener_width(elements, walk.index);
            const glues_opener = walk.depth == 0 and walk.glued and opener > 0;
            if (glues_opener) return width_within(walk.width + opener, budget);

            walk.depth += 1;
        },
        .joined => {
            walk.width += held.columns(element).leading;
            walk.index = group_end(elements, walk.index);
        },
        .pragma => return .{ .flat = walk.width },
        .line, .soft_line => {
            if (walk.depth == 0) return .{ .flat = walk.width };

            walk.glued = false;
            walk.width += @intFromBool(element == .line and !walk.blank);
        },
        .space => walk.width += @intFromBool(!walk.blank),
        .chunk, .starred, .text, .verbatim, .verbatim_arena => {
            const glued = held.suffix(element) and held.glues(walk.index, walk.depth + 1);
            if (glued) return .broken;

            walk.width = written(held, element, walk.width, budget) orelse return .broken;
        },
        .dedent, .@"align", .align_column, .dealign, .dedent_broken, .filled, .heads, .hugged => {},
        .hugging, .hugs, .if_broken, .indent, .indent_broken, .void, .reach => {},
        .reach_arrow, .reach_new, .reach_type, .reached, .wide => {},
        .if_flat => walk.width += held.columns(element).leading,
    }

    return null;
}

fn written(held: *const Measure, element: Element, width: u32, budget: u32) ?u32 {
    assert(width <= budget);
    assert(held.reads(element));

    const columns = held.columns(element);
    const found = width + columns.leading;

    if (!columns.broken) return found;

    assert(columns.leading + width == found);

    if (found <= budget) return columns.trailing;
    return null;
}

fn reach_width(held: *const Measure, start: u32, budget: u32, arrow: bool) Width {
    assert(budget < std.math.maxInt(u32));

    const elements = held.document.elements_slice();
    const count: u32 = @intCast(elements.len);

    assert(start < count);
    assert(elements[start] == .group_open);

    const width = body_width(held, elements, start, budget) orelse return .broken;

    var walk: ReachWalk = .{
        .arrow = arrow,
        .blank = false,
        .depth = 0,
        .index = group_end(elements, start + 1),
        .reached = false,
        .width = width,
    };

    while (walk.index < count) {
        if (walk.width > budget) break;

        const element = elements[walk.index];
        const spacing = element == .line or element == .space;
        const before = walk.width;

        walk.index += 1;

        if (reach_width_step(held, &walk, budget)) |found| return found;

        const advanced = spacing or walk.width > before;

        if (advanced) walk.blank = spacing;
    }

    return width_within(walk.width, budget);
}

fn reach_width_step(held: *const Measure, walk: *ReachWalk, budget: u32) ?Width {
    const elements = held.document.elements_slice();

    assert(walk.index > 0);
    assert(walk.width <= budget);

    const element = elements[walk.index - 1];

    switch (element) {
        .choice, .choice_close => {},
        .variant => walk.index = choice_end(elements, walk.index),
        .blank_line, .broken, .hard_line, .pragma => {
            const unreached = walk.depth > 0 and !walk.reached;
            if (unreached) return .broken;
            return .{ .flat = walk.width };
        },
        .group_open => walk.depth += 1,
        .group_close => {
            if (walk.depth > 0) {
                walk.depth -= 1;
                walk.reached = walk.reached or (!walk.arrow and walk.depth == 0);
            }
        },
        .joined => {
            walk.width += held.columns(element).leading;
            walk.index = group_end(elements, walk.index);
        },
        .line, .soft_line => {
            const ended = walk.reached or walk.depth == 0;
            if (ended) return .{ .flat = walk.width };

            walk.width += @intFromBool(element == .line and !walk.blank);
        },
        .space => walk.width += @intFromBool(!walk.blank),
        .chunk, .starred, .text, .verbatim, .verbatim_arena => {
            return reach_width_text(held, walk, budget);
        },
        .if_broken => {
            if (walk.reached) walk.width += held.columns(element).leading;
        },
        .dedent, .@"align", .align_column, .dealign, .dedent_broken, .filled, .heads => {},
        .hugged, .hugging, .hugs, .indent, .indent_broken, .reach => {},
        .reach_arrow, .reach_new, .reach_type, .reached, .void, .wide => {},
        .if_flat => walk.width += held.columns(element).leading,
    }

    return null;
}

fn reach_width_text(held: *const Measure, walk: *ReachWalk, budget: u32) ?Width {
    assert(walk.index > 0);
    assert(walk.width <= budget);

    const element = held.document.elements_slice()[walk.index - 1];
    const glued = held.suffix(element) and held.glues(walk.index, walk.depth + 1);
    if (glued) return .broken;

    const reaches = reach_texts and (walk.reached or walk.depth == 0);

    if (reaches) {
        const found = held.columns(element);

        if (found.broken) {
            const reached = walk.width + found.leading;
            if (reached <= budget) return .{ .flat = reached };
            return .broken;
        }
    }

    walk.width = written(held, element, walk.width, budget) orelse return .broken;

    switch (element) {
        .verbatim => |span| {
            const arrowed = walk.arrow and walk.depth == 0;
            const reaching = arrowed and std.mem.eql(u8, span.text(held.source), "=>");

            walk.reached = walk.reached or reaching;
        },
        else => {},
    }

    return null;
}

fn type_width(held: *const Measure, start: u32, budget: u32) Width {
    assert(budget < std.math.maxInt(u32));

    const elements = held.document.elements_slice();
    const count: u32 = @intCast(elements.len);

    assert(start < count);
    assert(elements[start] == .group_open);

    const width = body_width(held, elements, start, budget) orelse return .broken;

    var walk: TypeWalk = .{
        .blank = false,
        .depth = 0,
        .index = group_end(elements, start + 1),
        .nested = 0,
        .width = width,
    };

    while (walk.index < count) {
        if (walk.width > budget) break;

        const element = elements[walk.index];
        const spacing = element == .line or element == .space;
        const before = walk.width;

        walk.index += 1;

        if (type_width_step(held, &walk, budget)) |found| return found;

        const advanced = spacing or walk.width > before;

        if (advanced) walk.blank = spacing;
    }

    return width_within(walk.width, budget);
}

fn type_width_step(held: *const Measure, walk: *TypeWalk, budget: u32) ?Width {
    const elements = held.document.elements_slice();

    assert(walk.index > 0);
    assert(walk.width <= budget);

    const element = elements[walk.index - 1];

    switch (element) {
        .choice, .choice_close => {},
        .variant => walk.index = choice_end(elements, walk.index),
        .blank_line, .broken, .hard_line, .pragma => return .broken,
        .group_open => walk.depth += 1,
        .group_close => walk.depth -|= 1,
        .reach_new, .reach_type => walk.nested += 1,
        .reached => {
            if (walk.nested == 0) {
                return rest_width(held, walk.index, walk.width, budget, walk.blank);
            }

            walk.nested -= 1;
        },
        .joined => {
            walk.width += held.columns(element).leading;
            walk.index = group_end(elements, walk.index);
        },
        .line, .space => walk.width += @intFromBool(!walk.blank),
        .chunk, .starred, .text, .verbatim, .verbatim_arena => {
            walk.width += text_leading(held, walk.index, walk.depth + 1) orelse {
                return .broken;
            };
        },
        .dedent, .@"align", .align_column, .dealign, .dedent_broken, .filled, .heads => {},
        .hugged, .hugging, .hugs, .if_broken, .indent, .indent_broken => {},
        .reach, .reach_arrow, .soft_line, .void, .wide => {},
        .if_flat => walk.width += held.columns(element).leading,
    }

    return null;
}

fn rest_width(held: *const Measure, from: u32, found: u32, budget: u32, spaced: bool) Width {
    assert(from > 0);
    assert(found < std.math.maxInt(u32));
    assert(budget < std.math.maxInt(u32));

    const elements = held.document.elements_slice();
    const count: u32 = @intCast(elements.len);
    var blank = spaced;
    var index = from;
    var width = found;

    assert(from <= count);

    while (index < count) {
        const element = elements[index];
        const spacing = element == .line or element == .space;

        index += 1;

        if (element == .joined) {
            width += joined_first(held, index, blank);

            break;
        }

        const added = trailing(held, element, blank, false, index) orelse break;

        width += added;
        blank = spacing or (blank and added == 0);

        if (width > budget) return .broken;

        const texts = trailing_texts and held.columns(element).broken;
        if (texts) break;
    }

    return width_within(width, budget);
}

fn joined_first(held: *const Measure, from: u32, spaced: bool) u32 {
    assert(from > 0);

    const elements = held.document.elements_slice();
    const count: u32 = @intCast(elements.len);
    var blank = spaced;
    var index = from;
    var width: u32 = 0;

    assert(elements[from - 1] == .joined);

    while (index < count) {
        const element = elements[index];
        const spacing = element == .line or element == .space;

        index += 1;

        const added = trailing(held, element, blank, false, index) orelse break;

        width += added;
        blank = spacing or (blank and added == 0);
    }

    return width;
}

fn joined_width(held: *const Measure, start: u32, budget: u32, broken: bool) Width {
    assert(budget < std.math.maxInt(u32));

    const elements = held.document.elements_slice();

    assert(start < elements.len);
    assert(elements[start] == .group_open);

    const span = switch (elements[start + 1]) {
        .joined => |joined| joined,
        else => return .broken,
    };

    const width = held.columns(.{ .joined = span }).leading;
    const from = group_end(elements, start + 2);

    const found = switch (spanning(held, from, budget, width, .joined)) {
        .flat => |flat| flat,
        .broken => return .broken,
    };

    const owed = if (broken) owed_width(held, from) else 0;
    if (found + owed > budget) return .broken;
    return .{ .flat = found + owed };
}

fn owed_width(held: *const Measure, from: u32) u32 {
    assert(from < std.math.maxInt(u32));

    const elements = held.document.elements_slice();
    const count: u32 = @intCast(elements.len);
    var width: u32 = 0;
    var index = from;

    assert(from <= count);

    while (index < count) : (index += 1) {
        const element = elements[index];

        switch (element) {
            .dedent, .dedent_broken, .group_close => {},
            .if_broken => |span| width += span.length,
            .text => |held_text| {
                const bytes = span_bytes(
                    held.document,
                    held.source,
                    held.arena,
                    held_text.source,
                    held_text.span,
                );

                const comment = std.mem.startsWith(u8, bytes, "#");
                const gap = std.mem.trim(u8, bytes, " ").len == 0;
                const comma = std.mem.eql(u8, bytes, ",");
                const filler = comment or gap or comma;
                if (!filler) return width;

                width += held.columns(element).leading;
            },
            else => return width,
        }
    }

    assert(index == count);

    return width;
}

fn opener_width(elements: []const Element, start: u32) u32 {
    assert(start > 0);
    assert(elements[start - 1] == .group_open);

    const element = element_at(elements, start) orelse return 0;

    return switch (element) {
        .chunk, .starred, .verbatim, .verbatim_arena => |span| span.length,
        .text => |text| text.span.length,
        else => 0,
    };
}

fn width_within(width: u32, budget: u32) Width {
    assert(width < std.math.maxInt(u32));

    if (width > budget) return .broken;
    return .{ .flat = width };
}

fn fill_width(held: *const Measure, start: u32, budget: u32) u32 {
    assert(start < std.math.maxInt(u32));
    assert(budget < std.math.maxInt(u32));

    const elements = held.document.elements_slice();
    const count: u32 = @intCast(elements.len);
    const over_budget = budget + 1;
    var depth: u32 = 0;
    var index = start;
    var width: u32 = 0;

    assert(start <= count);
    assert(over_budget > budget);

    while (index < count) {
        const element = elements[index];

        index += 1;

        switch (element) {
            .group_open => depth += 1,
            .group_close => {
                if (depth == 0) return fill_width_closed(held, elements, index, width);

                depth -= 1;
            },
            .space => {
                if (fill_spaces) {
                    width += 1;

                    if (width > budget) return width;

                    continue;
                }
            },
            .line, .soft_line => {
                const nested = fill_nested_lines and depth > 0;
                if (!nested) return fill_width_ended(width, budget, depth);

                width += @intFromBool(element == .line);

                if (width > budget) return width;

                continue;
            },
            .blank_line, .broken, .hard_line => return fill_width_ended(width, budget, depth),
            .if_broken => {
                if (fill_width_spaced(elements, index, depth)) {
                    if (fill_space_ends) return width;

                    continue;
                }
            },
            else => {},
        }

        const found = held.columns(element);
        if (found.broken) return over_budget;

        const glued = held.suffix(element) and held.glues(index, depth + 1);
        if (glued) return over_budget;

        width += found.leading;

        if (width > budget) return width;
    }

    return width;
}

fn fill_width_closed(
    held: *const Measure,
    elements: []const Element,
    index: u32,
    width: u32,
) u32 {
    assert(index > 0);
    assert(elements[index - 1] == .group_close);
    assert(width < std.math.maxInt(u32));

    const next = element_at(elements, index) orelse return width;

    const following = switch (next) {
        .if_broken => held.columns(next).leading,
        else => 0,
    };

    const closed = width + following;

    assert(closed >= width);

    return closed;
}

fn fill_width_spaced(elements: []const Element, index: u32, depth: u32) bool {
    assert(index > 0);
    assert(elements[index - 1] == .if_broken);

    if (!fill_space_widths) return false;
    if (depth != 0) return false;
    if (!element_is(elements, index, .if_flat)) return false;
    return element_is(elements, index + 1, .soft_line);
}

fn fill_width_ended(width: u32, budget: u32, depth: u32) u32 {
    assert(depth <= group_depth_max);
    assert(width <= budget);

    if (depth == 0) return width;

    assert(budget + 1 > width);

    return budget + 1;
}

fn choice_end(elements: []const Element, start: u32) u32 {
    assert(elements.len <= std.math.maxInt(u32));
    assert(start < std.math.maxInt(u32));

    const count: u32 = @intCast(elements.len);
    var depth: u32 = 0;
    var index = start;

    while (index < count) {
        const element = elements[index];

        index += 1;

        if (element == .choice) depth += 1;

        if (element == .choice_close) {
            if (depth == 0) return index;

            depth -= 1;
        }
    }

    assert(index >= count);
    assert(index >= start);

    return index;
}

fn group_end(elements: []const Element, start: u32) u32 {
    assert(elements.len <= std.math.maxInt(u32));
    assert(start < std.math.maxInt(u32));

    const count: u32 = @intCast(elements.len);
    var depth: u32 = 0;
    var index = start;

    while (index < count) {
        const element = elements[index];

        index += 1;

        if (element == .group_open) depth += 1;

        if (element == .group_close) {
            if (depth == 0) return index;

            depth -= 1;
        }
    }

    assert(index >= count);
    assert(index >= start);

    return index;
}

fn element_at(elements: []const Element, index: u32) ?Element {
    assert(elements.len <= std.math.maxInt(u32));

    if (index >= elements.len) return null;
    return elements[index];
}

fn element_is(elements: []const Element, index: u32, comptime tag: std.meta.Tag(Element)) bool {
    comptime assert(tag != .void);
    assert(elements.len <= std.math.maxInt(u32));
    assert(index < std.math.maxInt(u32));

    const element = element_at(elements, index) orelse return false;
    const found = element == tag;

    if (found) assert(index < elements.len);

    return found;
}

fn columns_of(bytes: []const u8, tab: u32) Columns {
    assert(bytes.len <= std.math.maxInt(u32));
    assert(tab < std.math.maxInt(u32));

    if (ascii_only(bytes)) return ascii_columns_of(bytes, tab);

    var broken = false;
    var held: u32 = 0;
    var leading: u32 = 0;
    var width: u32 = 0;

    while (held < bytes.len) {
        if (bytes[held] == '\n') {
            if (!broken) leading = width;

            broken = true;
            width = 0;
            held += 1;

            continue;
        }

        const character = decoded(bytes, held);
        const tabbed = tab_columns and character.code == '\t';

        width += if (tabbed) tab else point_columns(character.code);
        held += character.step;
    }

    assert(held == bytes.len);

    if (broken) return .{ .leading = leading, .trailing = width, .broken = true };
    return .{ .leading = width, .trailing = width, .broken = false };
}

fn ascii_columns_of(bytes: []const u8, tab: u32) Columns {
    assert(bytes.len <= std.math.maxInt(u32));
    assert(tab < std.math.maxInt(u32));

    const width = tabbed_columns(bytes, tab);

    const first = std.mem.findScalar(u8, bytes, '\n') orelse {
        return .{ .leading = width, .trailing = width, .broken = false };
    };

    const last = std.mem.findScalarLast(u8, bytes, '\n') orelse unreachable;

    assert(first <= last);
    assert(last < bytes.len);

    return .{
        .leading = tabbed_columns(bytes[0..first], tab),
        .trailing = tabbed_columns(bytes[last + 1 ..], tab),
        .broken = true,
    };
}

fn tabbed_columns(bytes: []const u8, tab: u32) u32 {
    assert(bytes.len <= std.math.maxInt(u32));

    const length: u32 = @intCast(bytes.len);
    const tabs: u32 = if (tab_columns) @intCast(std.mem.count(u8, bytes, "\t")) else 0;

    assert(tabs <= length);

    const columns = length + tabs * (tab -| 1);

    assert(columns >= length);

    return columns;
}

fn ascii_only(bytes: []const u8) bool {
    assert(bytes.len <= std.math.maxInt(u32));

    for (bytes) |byte| {
        if (byte >= 0x80) return false;
    }

    return true;
}

fn decoded(bytes: []const u8, offset: u32) Decoded {
    assert(offset < bytes.len);

    const lead = bytes[offset];

    const shape: Lead = switch (lead) {
        0x00...0x7f => return .{ .code = lead, .step = 1 },
        0xc0...0xdf => .{ .width = 2, .mask = 0x1f },
        0xe0...0xef => .{ .width = 3, .mask = 0x0f },
        0xf0...0xf7 => .{ .width = 4, .mask = 0x07 },
        else => return .{ .code = lead, .step = 1 },
    };

    if (offset + shape.width > bytes.len) return .{ .code = lead, .step = 1 };

    var held: u32 = lead & shape.mask;

    for (bytes[offset + 1 .. offset + shape.width]) |continuation| {
        held = (held << 6) | (continuation & 0x3f);
    }

    assert(held < 1 << 21);

    return .{ .code = held, .step = shape.width };
}

const source_words = "alpha bravo charlie delta echo foxtrot golf hotel india juliet";

const Built = struct {
    document: Document,

    fn init() error{OutOfMemory}!Built {
        const document = try Document.init(std.testing.allocator, 1 << 8, 1 << 4);

        assert(document.count() == 0);
        assert(document.balanced());

        return .{ .document = document };
    }

    fn deinit(built: *Built) void {
        assert(built.document.count() <= 1 << 8);
        assert(built.document.balanced());

        built.document.deinit(std.testing.allocator);
    }

    fn push(built: *Built, element: Element) void {
        assert(built.document.closes(element));

        const count = built.document.count();

        assert(count < 1 << 8);

        built.document.push(element) catch unreachable;

        assert(built.document.count() == count + 1);
    }

    fn word(built: *Built, offset: u32, length: u32) void {
        assert(length > 0);
        assert(offset + length <= source_words.len);

        built.push(.{ .text = .{
            .source = .document,
            .span = .{ .offset = offset, .length = length },
        } });
    }
};

fn options_of(line_width: u32) Options {
    assert(line_width > 0);

    var held = Options.default;

    held.line_width = line_width;

    assert(held.indent_width == Options.default.indent_width);

    return held;
}

fn printed(built: *const Built, line_width: u32) error{ OutOfMemory, Overflow }![]u8 {
    var out = try Buffer.init(std.testing.allocator, 1 << 12);
    defer out.deinit(std.testing.allocator);

    assert(line_width > 0);

    try print(&built.document, source_words, "", options_of(line_width), &out);

    assert(out.count() <= 1 << 12);

    return std.testing.allocator.dupe(u8, out.const_slice());
}

fn expect_printed(expected: []const u8, actual: []u8) !void {
    assert(actual.len <= 1 << 12);

    defer std.testing.allocator.free(actual);

    assert(expected.len <= 1 << 12);

    try std.testing.expectEqualStrings(expected, actual);
}

fn grouped() error{OutOfMemory}!Built {
    var built = try Built.init();

    built.push(.group_open);
    built.word(0, 5);
    built.push(.line);
    built.word(6, 5);
    built.push(.line);
    built.word(12, 7);
    built.push(.group_close);

    assert(built.document.count() == 7);
    assert(built.document.balanced());

    return built;
}

fn choice(width: u32, first: u32, second: u32) error{ OutOfMemory, Overflow }![]u8 {
    assert(second < std.math.maxInt(u32));

    var built = try Built.init();
    defer built.deinit();

    assert(width > 0);
    assert(first > 0);

    built.push(.{ .choice = 2 });
    built.push(.group_open);
    built.word(0, first);
    built.push(.group_close);
    built.push(.variant);
    built.push(.group_open);
    built.word(0, second);
    built.push(.hard_line);
    built.word(6, 5);
    built.push(.group_close);
    built.push(.choice_close);

    return printed(&built, width);
}

test "a group that fits prints flat and a narrow one breaks" {
    var built = try grouped();
    defer built.deinit();

    try expect_printed("alpha bravo charlie", try printed(&built, 80));
    try expect_printed("alpha\nbravo\ncharlie", try printed(&built, 8));
}

test "a hard line breaks its group at any width" {
    var built = try Built.init();
    defer built.deinit();

    built.push(.group_open);
    built.word(0, 5);
    built.push(.hard_line);
    built.word(6, 5);
    built.push(.line);
    built.word(12, 7);
    built.push(.group_close);

    try expect_printed("alpha\nbravo\ncharlie", try printed(&built, 1 << 10));
}

test "a nested group breaks outermost first" {
    var built = try Built.init();
    defer built.deinit();

    built.push(.group_open);
    built.word(0, 5);
    built.push(.line);
    built.push(.group_open);
    built.word(6, 5);
    built.push(.line);
    built.word(12, 7);
    built.push(.group_close);
    built.push(.group_close);

    try expect_printed("alpha bravo charlie", try printed(&built, 80));
    try expect_printed("alpha\nbravo charlie", try printed(&built, 16));
    try expect_printed("alpha\nbravo\ncharlie", try printed(&built, 8));
}

test "an if broken element prints only in the broken state" {
    var built = try Built.init();
    defer built.deinit();

    const comma = built.document.literal(",");
    const span = built.document.literal_span(comma);

    built.push(.group_open);
    built.word(0, 5);
    built.push(.{ .if_broken = span });
    built.push(.line);
    built.word(6, 5);
    built.push(.{ .if_broken = span });
    built.push(.group_close);

    try expect_printed("alpha bravo", try printed(&built, 80));
    try expect_printed("alpha,\nbravo,", try printed(&built, 4));
}

test "an indent changes the next line and nothing else" {
    var built = try Built.init();
    defer built.deinit();

    built.word(0, 5);
    built.push(.indent);
    built.push(.hard_line);
    built.word(6, 5);
    built.push(.indent);
    built.push(.hard_line);
    built.word(12, 7);
    built.push(.dedent);
    built.push(.dedent);
    built.push(.hard_line);
    built.word(20, 5);

    try expect_printed("alpha\n    bravo\n        charlie\ndelta", try printed(&built, 80));
}

test "an indent of tabs writes one tab a level" {
    var built = try Built.init();
    defer built.deinit();

    var out = try Buffer.init(std.testing.allocator, 1 << 8);
    defer out.deinit(std.testing.allocator);

    built.word(0, 5);
    built.push(.indent);
    built.push(.hard_line);
    built.word(6, 5);
    built.push(.dedent);

    var held = Options.default;

    held.tabs = true;

    try print(&built.document, source_words, "", held, &out);
    try std.testing.expectEqualStrings("alpha\n\tbravo", out.const_slice());
}

test "a blank line emits exactly its count" {
    for (0..3) |count| {
        const lines: u32 = @intCast(count);
        var built = try Built.init();
        defer built.deinit();

        built.word(0, 5);
        built.push(.hard_line);
        built.push(.{ .blank_line = lines });
        built.word(6, 5);

        var expected: [16]u8 = undefined;

        @memcpy(expected[0..6], "alpha\n");
        @memset(expected[6..][0..lines], '\n');
        @memcpy(expected[6 + lines ..][0..5], "bravo");

        try expect_printed(expected[0 .. 11 + lines], try printed(&built, 80));
    }
}

test "a verbatim element keeps every byte it holds" {
    const held = "x = '''\n    a  \n\tb\n'''";
    var built = try Built.init();
    defer built.deinit();

    var out = try Buffer.init(std.testing.allocator, 1 << 8);
    defer out.deinit(std.testing.allocator);

    built.push(.indent);
    built.push(.{ .verbatim = .{ .offset = 0, .length = held.len } });
    built.push(.hard_line);
    built.push(.dedent);

    try print(&built.document, held, "", Options.default, &out);
    try std.testing.expectEqualStrings("    x = '''\n    a  \n\tb\n'''\n", out.const_slice());
}

test "a verbatim element resets the column from its last break" {
    const held = "aaaa\nbb";
    var built = try Built.init();
    defer built.deinit();

    var out = try Buffer.init(std.testing.allocator, 1 << 8);
    defer out.deinit(std.testing.allocator);

    built.push(.{ .verbatim = .{ .offset = 0, .length = held.len } });
    built.push(.group_open);
    built.push(.line);
    built.push(.{ .text = .{ .source = .document, .span = .{ .offset = 0, .length = 4 } } });
    built.push(.group_close);

    try print(&built.document, held, "", options_of(8), &out);
    try std.testing.expectEqualStrings("aaaa\nbb aaaa", out.const_slice());
}

test "an arena text element reads the arena" {
    const arena = "rendered";
    var built = try Built.init();
    defer built.deinit();

    var out = try Buffer.init(std.testing.allocator, 1 << 8);
    defer out.deinit(std.testing.allocator);

    built.push(.{ .text = .{ .source = .arena, .span = .{ .offset = 0, .length = 8 } } });

    try print(&built.document, source_words, arena, Options.default, &out);
    try std.testing.expectEqualStrings("rendered", out.const_slice());
}

test "an output overflow clears the target" {
    var built = try grouped();
    defer built.deinit();

    var out = try Buffer.init(std.testing.allocator, 4);
    defer out.deinit(std.testing.allocator);

    const result = print(&built.document, source_words, "", Options.default, &out);

    try std.testing.expectError(error.Overflow, result);
    try std.testing.expect(out.empty());
}

test "a space before a break is never written" {
    var built = try Built.init();
    defer built.deinit();

    built.word(0, 5);
    built.push(.space);
    built.push(.hard_line);
    built.push(.space);
    built.word(6, 5);

    try expect_printed("alpha\nbravo", try printed(&built, 80));
}

test "a choice takes the first variant that fits flat" {
    try expect_printed("alpha", try choice(40, 5, 5));
}

test "a choice takes the last variant when none of them fits" {
    try expect_printed("alpha\nbravo", try choice(3, 5, 5));
}

test "a choice reads a forced break in a variant as one that does not fit" {
    var built = try Built.init();
    defer built.deinit();

    built.push(.{ .choice = 2 });
    built.push(.group_open);
    built.word(0, 5);
    built.push(.hard_line);
    built.word(6, 5);
    built.push(.group_close);
    built.push(.variant);
    built.push(.group_open);
    built.word(12, 7);
    built.push(.group_close);
    built.push(.choice_close);

    try expect_printed("charlie", try printed(&built, 80));
}

test "a choice nested in a losing variant is never printed" {
    var built = try Built.init();
    defer built.deinit();

    built.push(.{ .choice = 2 });
    built.push(.group_open);
    built.push(.{ .choice = 2 });
    built.push(.group_open);
    built.word(0, 5);
    built.push(.hard_line);
    built.word(6, 5);
    built.push(.group_close);
    built.push(.variant);
    built.push(.group_open);
    built.word(6, 5);
    built.push(.hard_line);
    built.word(0, 5);
    built.push(.group_close);
    built.push(.choice_close);
    built.push(.group_close);
    built.push(.variant);
    built.push(.group_open);
    built.word(12, 7);
    built.push(.group_close);
    built.push(.choice_close);

    try expect_printed("charlie", try printed(&built, 80));
}

test "a choice the line is too narrow for still prints its last variant whole" {
    var built = try Built.init();
    defer built.deinit();

    built.push(.{ .choice = 3 });
    built.push(.group_open);
    built.word(0, 5);
    built.push(.space);
    built.word(6, 5);
    built.push(.group_close);
    built.push(.variant);
    built.push(.group_open);
    built.word(0, 5);
    built.push(.group_close);
    built.push(.variant);
    built.push(.group_open);
    built.word(12, 7);
    built.push(.group_close);
    built.push(.choice_close);

    try expect_printed("alpha bravo", try printed(&built, 80));
    try expect_printed("alpha", try printed(&built, 8));
    try expect_printed("charlie", try printed(&built, 4));
}
