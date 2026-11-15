const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../stdx/bounded/array.zig").ArrayType;
const Buffer = @import("../stdx/bounded/buffer.zig");
const Document = @import("ir.zig").Document;
const Element = @import("ir.zig").Element;
const EventsType = @import("../syntax/tree.zig").EventsType;
const Fields = @import("python/field.zig").Fields;
const FormatterError = @import("formatters.zig").FormatterError;
pub const Kind = @import("../syntax/python/kind.zig").Kind;
const LineEnding = @import("../text/line_ending.zig").LineEnding;
const Options = @import("print.zig").Options;
const Parser = @import("../syntax/python/parse.zig").Parser;
const Powers = @import("python/power.zig").Powers;
const PragmaAt = @import("pragma.zig").PragmaAt;
const Span = @import("../stdx/bounded/span.zig");
const Statement = @import("python/stub.zig").Statement;
const Structure = @import("../syntax/tree.zig").Structure;
const Token = @import("../syntax/token.zig");
const Tokens = @import("../syntax/tokens.zig");
const Tree = @import("../syntax/tree.zig").TreeType(Kind);
const blank_between = @import("python/blank.zig").between;
const body_edges = @import("python/literal.zig").body_edges;
const body_escaped = @import("python/literal.zig").body_escaped;
const body_indent = @import("python/literal.zig").body_indent;
const byte_at = @import("../text/scan.zig").byte_at;
const columns = @import("walk.zig").columns;
const concat = @import("python/concat.zig");
const docstrings = @import("python/docstring.zig");
const elided = @import("python/elided.zig");
const ending_of = @import("python/literal.zig").ending_of;
const escapes_of = @import("python/literal.zig").escapes_of;
const field = @import("python/field.zig");
const interpolated = @import("python/interpolated.zig");
const is_line_edge = @import("python/selection.zig").is_line_edge;
const is_word = @import("python/selection.zig").is_word;
const lex = @import("../syntax/lex.zig").lex;
const line_break_width = @import("../text/scan.zig").line_break_width;
const line_end_of = @import("python/selection.zig").line_end_of;
const line_start_of = @import("python/selection.zig").line_start_of;
const numbered = @import("python/literal.zig").numbered;
const odd_slashes = @import("python/literal.zig").odd_slashes;
const onset = @import("python/onset.zig");
const other_quote = @import("python/literal.zig").other_quote;
const power = @import("python/power.zig");
const pragmatic = @import("python/literal.zig").pragmatic;
const preferring = @import("python/literal.zig").preferring;
const prefix_of = @import("python/literal.zig").prefix_of;
const print = @import("print.zig").print;
const quote_edges = @import("python/literal.zig").quote_edges;
const quoted_body = @import("python/literal.zig").quoted_body;
const range_span = @import("python/selection.zig").range_span;
const raw_of = @import("../syntax/raw.zig").raw_of;
const relettered = @import("python/literal.zig").relettered;
const requoted = @import("python/literal.zig").requoted;
const settled = @import("python/literal.zig").settled;
const slice = @import("python/slice.zig");
const source_span = @import("python/selection.zig").source_span;
const spanned = @import("python/spanned.zig");
const statements_of = @import("python/selection.zig").statements_of;
const stub_file = @import("python/stub.zig");
const target = @import("python/target.zig");
const triple_double = @import("python/literal.zig").triple_double;
const triple_single = @import("python/literal.zig").triple_single;
const vertical = @import("python/blank.zig");
const word_positions = @import("python/selection.zig").word_positions;
const word_span = @import("python/selection.zig").word_span;
const words_before = @import("python/selection.zig").words_before;

pub const Formatter = struct {
    arena: Buffer,
    close: u32,
    comma: u32,
    continuation: u32,
    document: Document,
    gap: u32,
    head: u32,
    open: u32,
    spacer: u32,
    statements: [bracket_depth_max + 1]Statement,

    pub fn init(
        gpa: std.mem.Allocator,
        element_count_max: u32,
        arena_bytes_max: u32,
    ) std.mem.Allocator.Error!Formatter {
        assert(element_count_max > 0);
        assert(arena_bytes_max > 0);

        var document: Document = try .init(gpa, element_count_max, literal_count_max);
        errdefer document.deinit(gpa);

        const comma_index = document.literal(comma);
        const gap_index = document.literal(gap);
        const open_index = document.literal(paren_open);
        const head_index = document.literal(paren_head);
        const spacer_index = document.literal(spacer);
        const continuation_index = document.literal(continuation);
        const close_index = document.literal(paren_close);

        assert(comma_index == 0);
        assert(close_index + 1 == literal_count_max);

        const arena: Buffer = try .init(gpa, arena_bytes_max);

        return .{
            .arena = arena,
            .close = close_index,
            .comma = comma_index,
            .continuation = continuation_index,
            .document = document,
            .gap = gap_index,
            .head = head_index,
            .open = open_index,
            .spacer = spacer_index,
            .statements = @splat(.none),
        };
    }

    pub fn deinit(formatter: *Formatter, gpa: std.mem.Allocator) void {
        assert(formatter.arena.count() <= formatter.arena.capacity());
        assert(formatter.close < literal_count_max);

        formatter.document.deinit(gpa);
        formatter.arena.deinit(gpa);
        formatter.* = undefined;
    }

    pub fn format(formatter: *Formatter, input: *const Input, out: *Buffer) FormatterError!void {
        assert(input.tokens.len == input.raw.len);
        assert(pragmas_sorted(input.pragmas));

        if (format_refused(input)) return error.SourceInvalid;

        formatter.format_emitted(input, out) catch |err| switch (err) {
            error.Overflow => return error.OutputExhausted,
        };
    }

    pub fn format_range(
        formatter: *Formatter,
        input: *const Input,
        selection: Span,
        scratch: *Buffer,
        lexed: *Tokens,
        out: *Buffer,
    ) FormatterError!Span {
        assert(input.tokens.len == input.raw.len);
        assert(selection.length <= std.math.maxInt(u32) - selection.offset);

        try formatter.format(input, scratch);

        const statements = statements_of(input.tree, input.tokens, selection) orelse {
            return error.SourceInvalid;
        };

        const before = words_before(input.tokens, input.tree.at(statements.first).token_start);
        const after = words_before(input.tokens, input.tree.at(statements.last).token_end);

        lexed.clear();

        lex(.of(.python), scratch.const_slice(), lexed) catch |err| switch (err) {
            error.Truncated => return error.OutputExhausted,
        };

        const held = word_span(lexed.slice(), before, after) orelse return error.SourceInvalid;

        out.clear();

        out.push(held.text(scratch.const_slice())) catch |err| switch (err) {
            error.Overflow => return error.OutputExhausted,
        };

        return source_span(input.source, input.tree, input.tokens, statements);
    }

    pub fn range(
        formatter: *Formatter,
        input: *const Input,
        lines: Run,
        out: *Buffer,
    ) FormatterError!Span {
        assert(lines.first <= lines.last);
        assert(input.tokens.len == input.raw.len);

        try formatter.format(input, out);

        return range_span(out.const_slice(), lines) orelse error.SourceInvalid;
    }

    fn format_emitted(
        formatter: *Formatter,
        input: *const Input,
        out: *Buffer,
    ) error{Overflow}!void {
        assert(input.outcome == .complete);
        assert(input.tree.diagnostic_slice().len == 0);

        formatter.arena.clear();
        formatter.document.clear();
        formatter.statements = @splat(.none);

        var emitter = emitting(input, formatter);

        try emitter.run();

        try print(
            &formatter.document,
            input.source,
            formatter.arena.const_slice(),
            input.options,
            out,
        );

        try formatter.reline(input.line_ending, out);
    }

    fn parentheses(formatter: *const Formatter) Parentheses {
        assert(formatter.open != formatter.close);
        assert(formatter.head < literal_count_max);

        return .{ .open = formatter.open, .head = formatter.head, .close = formatter.close };
    }

    fn literals(formatter: *const Formatter) Literals {
        assert(formatter.comma != formatter.gap);
        assert(formatter.close < literal_count_max);

        return .{
            .comma = formatter.comma,
            .continuation = formatter.continuation,
            .gap = formatter.gap,
            .spacer = formatter.spacer,
        };
    }

    fn reline(formatter: *Formatter, ending: LineEnding, out: *Buffer) error{Overflow}!void {
        const carriage = std.mem.findScalar(u8, out.const_slice(), '\r') != null;
        const unchanged = ending == .line_feed and !carriage;
        if (unchanged) return;

        formatter.arena.clear();
        try formatter.arena.push(out.const_slice());
        out.clear();

        const bytes = formatter.arena.const_slice();
        var offset: u32 = 0;

        for (0..bytes.len) |_| {
            if (offset >= bytes.len) break;

            const width = line_break_width(bytes, offset);

            if (width > 0) {
                try out.push(ending.bytes());
            } else {
                try out.push(bytes[offset .. offset + 1]);
            }

            offset += @max(width, 1);
        }

        const carried = std.mem.findScalar(u8, out.const_slice(), '\r') != null;

        assert(offset == bytes.len);
        if (ending == .line_feed) assert(!carried);
    }
};

pub const Input = struct {
    line_ending: LineEnding,
    magic_trailing_comma: bool,
    options: Options,
    outcome: Structure,
    pragmas: []const PragmaAt,
    quote: QuotePreference,
    raw: []const Kind,
    source: []const u8,
    stub: bool,
    tokens: []const Token,
    tree: *const Tree,

    pub const defaults: Defaults = .{
        .line_ending = .line_feed,
        .magic_trailing_comma = true,
        .quote = .double,
    };
};

pub const Defaults = struct {
    line_ending: LineEnding,
    magic_trailing_comma: bool,
    quote: QuotePreference,
};

pub const QuotePreference = enum {
    double,
    preserve,
    single,

    pub fn byte(preference: QuotePreference) u8 {
        const quote: u8 = switch (preference) {
            .double => '"',
            .preserve => 0,
            .single => '\'',
        };

        if (preference == .preserve) assert(quote == 0);
        if (quote != 0) assert(preferring(quote) == preference);

        return quote;
    }
};

pub const Run = struct {
    first: u32,
    last: u32,
};

pub const Emitter = struct {
    after: bool,
    arena: *Buffer,
    at_lambda: ?u32,
    at_previous: ?u32,
    blocks: [bracket_depth_max]bool,
    closed: bool,
    columns: [bracket_depth_max]u32,
    concat_at: ?u32,
    concat_span: Span,
    continued: bool,
    depth: u32,
    document: *Document,
    documented: bool,
    documented_past: bool,
    elided: [bracket_depth_max]u32,
    elided_line: LineElisions,
    elisions: u32,
    formatted: interpolated.Formatted,
    frames: [bracket_depth_max]Frame,
    functions: [bracket_depth_max]bool,
    hug_break: ?u32,
    hug_depth: u32,
    hug_end: ?u32,
    hugged: bool,
    indent: u32,
    indent_width: u32,
    @"inline": u32,
    line_depth: u32,
    line_first: ?Kind,
    line_first_at: ?u32,
    line_width: u32,
    literals: Literals,
    lowered: u32,
    magic_trailing_comma: bool,
    opened: bool,
    parentheses: Parentheses,
    pending_break: bool,
    pending_word: ?PendingWord,
    powers: Powers,
    pragmas: []const PragmaAt,
    previous: ?Kind,
    quote: QuotePreference,
    raw: []const Kind,
    skip: ?u32,
    source: []const u8,
    starting: bool,
    statements: *[bracket_depth_max + 1]Statement,
    stub: bool,
    stubbed: bool,
    stubbed_function: bool,
    suppress_space: bool,
    tokens: []const Token,
    until: u32,
    walrus: bool,
    wrap: ?u32,
    wrap_depth: u32,
    wrap_headed: bool,
    wrap_outer: Frame,
    wrap_sole: bool,
    wrap_tuple: bool,
    wrapper: Frame,

    fn break_line(emitter: *Emitter, position: u32) error{Overflow}!void {
        assert(position < emitter.tokens.len);
        assert(emitter.indent <= bracket_depth_max);

        const blanks = emitter.break_line_blanks(position);
        const documenting = emitter.documented and emitter.documented_past;
        const carried = documenting and emitter.indent == 0 and emitter.raw[position] == .comment;

        assert(blanks <= 2);

        emitter.after = false;
        emitter.closed = false;
        emitter.documented = carried;
        emitter.documented_past = carried and emitter.comments_trail(position);
        emitter.stubbed = false;
        emitter.stubbed_function = false;
        emitter.at_lambda = null;
        emitter.opened = false;
        emitter.pending_break = false;
        emitter.suppress_space = false;

        try emitter.document.push(.hard_line);
        try emitter.document.push(.{ .blank_line = blanks });
    }

    fn break_line_blanks(emitter: *const Emitter, position: u32) u32 {
        assert(position < emitter.tokens.len);
        assert(emitter.depth <= bracket_depth_max);

        const kind = emitter.raw[position];
        const inset = emitter.indent > 0 or emitter.stub;
        const allowed: u32 = if (inset) 1 else 2;
        const offset = emitter.tokens[position].offset;
        const before = @min(emitter.blanks_before(position, offset), allowed);
        const held: u32 = if (emitter.ends_semicolon(position)) 0 else before;
        const opening = emitter.opens_definition(position);
        const headed = vertical.heads_a_definition(emitter, position);
        const following = vertical.follows_a_comment(emitter, position);
        const overloaded = emitter.stub or vertical.overloads(emitter, position);
        const stubbed = emitter.stubbed and held == 0 and (opening or headed) and overloaded;
        const definition = !stubbed and ((opening and !following) or headed);
        const trailing = kind == .comment and position > 0 and emitter.comments_trail(position - 1);
        const closed = if (trailing) emitter.closed else emitter.after;
        const continued = emitter.continues(position);
        const stubbed_open = emitter.stubbed and !stubbed and !continued;
        const separated = (closed and !continued) or definition or stubbed_open;
        const inside = if (emitter.previous) |previous| is_open(previous) else false;
        const hugged = is_close(kind) or inside;

        const nested = !emitter.stub and emitter.opened and emitter.nests() and opening and
            !following;

        const documented = emitter.documented and !separated;
        const trailed_before = emitter.comments_trail(position -| 1);
        const imported = emitter.follows_an_import(position) and !trailed_before;
        const functional = emitter.indent > 0 and emitter.functions[emitter.indent - 1];
        const heads = emitter.opened and functional and kind != .string_plain;
        const enclosing = emitter.depth > 0 or emitter.elisions > 0;
        const flush = enclosing or emitter.line_first == .at or hugged;
        const enclosed = emitter.opened and !nested and !heads;
        const spaced_line = separated and emitter.at_previous != null;

        assert(held <= allowed);

        if (flush) return 0;
        if (vertical.resumes(emitter, position)) return held;
        if (enclosed) return 0;
        if (heads) return held;

        if (emitter.stub) {
            if (stub_file.blanks(emitter, position, held)) |blanks| return blanks;
        } else if (spaced_line) {
            return allowed;
        } else {}

        if (documented) return if (emitter.documented_past) held else 1;
        if (imported) return @max(held, 1);
        return held;
    }

    fn close(emitter: *Emitter, position: u32, kind: Kind) error{Overflow}!void {
        assert(is_close(kind));
        assert(emitter.depth <= bracket_depth_max);
        assert(position < emitter.tokens.len);

        const held = emitter.frame();
        const matched = emitter.depth > 0 and held.kind == opened_by(kind);
        if (!matched) return emitter.text(position, false);

        if (held.hugged) {
            emitter.depth -= 1;

            return emitter.text(position, false);
        }

        try emitter.ends_element(0);

        emitter.depth -= 1;

        const trailing = emitter.document.literal_span(emitter.literals.comma);
        const started = emitter.starting;
        const separating: Element = if (held.magic) .hard_line else .soft_line;
        const commas = !started and !held.trailed and held.commas;
        const closes = !held.sole and !held.hollow and !held.commented;
        const owed = !started and !held.trailed and !held.commas and held.owes;

        if (commas) try emitter.document.push(.{ .if_broken = trailing });
        if (closes) try emitter.document.push(.group_close);
        if (owed) try emitter.document.push(.{ .if_broken = trailing });

        try emitter.document.push(.dedent);

        if (!started) try emitter.document.push(separating);

        try emitter.text(position, false);
        try emitter.document.push(.group_close);
    }

    pub fn frame(emitter: *const Emitter) Frame {
        assert(emitter.depth <= bracket_depth_max);

        const held = if (emitter.depth == 0) emitter.wrapper else emitter.frames[emitter.depth - 1];

        assert(held.level_count <= element_depth_max);
        assert(held.group_count <= element_depth_max);

        return held;
    }

    fn set_frame(emitter: *Emitter, held: *const Frame) void {
        assert(emitter.depth <= bracket_depth_max);
        assert(held.level_count <= element_depth_max);

        if (emitter.depth == 0) {
            emitter.wrapper = held.*;

            return;
        }

        emitter.frames[emitter.depth - 1] = held.*;
    }

    fn ends_semicolon(emitter: *const Emitter, position: u32) bool {
        assert(position < emitter.raw.len);
        assert(emitter.raw.len == emitter.tokens.len);

        var scan = position;

        while (scan > 0) {
            scan -= 1;

            const kind = emitter.raw[scan];
            if (is_layout(kind)) continue;
            return kind == .semicolon;
        }

        return false;
    }

    pub fn blanks_before(emitter: *const Emitter, position: u32, offset: u32) u32 {
        assert(position <= emitter.tokens.len);
        assert(offset <= emitter.source.len);

        var scan = position;

        while (scan > 0) {
            scan -= 1;

            const held = emitter.tokens[scan];
            if (held.length == 0) continue;

            const breaks = blank_lines(emitter.source, held.end(), offset);
            if (emitter.raw[scan] == .newline) return breaks;
            assert(breaks -| 1 < std.math.maxInt(u32));

            return breaks -| 1;
        }

        return blank_lines(emitter.source, 0, offset);
    }

    fn parted(emitter: *const Emitter) bool {
        const elements = emitter.document.elements_slice();

        assert(elements.len == emitter.document.count());
        assert(emitter.depth <= bracket_depth_max);

        for (0..elements.len) |distance| {
            switch (elements[elements.len - 1 - distance]) {
                .blank_line, .hard_line, .line, .soft_line => return true,
                .dedent, .group_close, .group_open, .indent => {},
                .if_broken => |span| if (span.offset != emitter.literals.comma) return false,
                else => return false,
            }
        }

        return true;
    }

    pub fn pragma_at(emitter: *const Emitter, position: u32) ?Pragma {
        assert(position < emitter.raw.len);
        assert(emitter.raw.len == emitter.tokens.len);

        if (emitter.raw[position] != .comment) return null;

        const offset = emitter.tokens[position].offset;
        const found = std.sort.binarySearch(PragmaAt, emitter.pragmas, offset, pragma_at_order);
        const index = found orelse return null;

        assert(emitter.pragmas[index].span.offset == offset);

        return emitter.pragmas[index].kind;
    }

    fn region_end(emitter: *const Emitter, position: u32) ?u32 {
        assert(position < emitter.raw.len);
        assert(emitter.raw.len == emitter.tokens.len);

        const midline = !emitter.pending_break and emitter.previous != null;
        if (midline) return null;
        if (emitter.pragma_at(position) == .format_off) return emitter.format_off_end(position);

        const end = emitter.format_skip_end(position);

        if (end) |held| assert(held >= position);

        return end;
    }

    fn format_off_end(emitter: *const Emitter, position: u32) u32 {
        assert(position < emitter.tokens.len);
        assert(emitter.raw[position] == .comment);

        const count: u32 = @intCast(emitter.tokens.len);
        const column = emitter.line_indent(emitter.tokens[position].offset);
        var last = position;
        var scan = position + 1;

        while (scan < count) : (scan += 1) {
            if (is_layout(emitter.raw[scan])) {
                last = scan;

                continue;
            }

            const held = emitter.line_indent(emitter.tokens[scan].offset);
            const resumed = emitter.pragma_at(scan) == .format_on and held == column;

            if (resumed) {
                assert(scan <= emitter.tokens.len);

                return scan;
            }

            if (held < column) return last;

            last = scan;
        }

        assert(last < count);

        return last;
    }

    pub fn line_indent(emitter: *const Emitter, offset: u32) u32 {
        assert(offset <= emitter.source.len);

        const start = emitter.line_start(offset);
        const rest = emitter.source[start..];
        const width = std.mem.findNone(u8, rest, " \t") orelse rest.len;

        assert(start + width <= emitter.source.len);

        return @intCast(width);
    }

    fn format_skip_end(emitter: *const Emitter, position: u32) ?u32 {
        assert(position < emitter.raw.len);
        assert(emitter.raw.len == emitter.tokens.len);

        const count: u32 = @intCast(emitter.tokens.len);
        var found = false;
        var scan = position;

        while (scan < count) : (scan += 1) {
            if (is_layout(emitter.raw[scan])) break;

            found = found or emitter.pragma_at(scan) == .format_skip;
        }

        if (!found) return null;

        assert(scan > position);

        return scan - 1;
    }

    pub fn heads_line(emitter: *const Emitter, position: u32) bool {
        assert(position < emitter.tokens.len);

        const offset = emitter.tokens[position].offset;
        const start = emitter.line_start(offset);
        const result = offset == start + emitter.line_indent(offset);

        if (result) assert(std.mem.findNone(u8, emitter.source[start..offset], " \t") == null);

        return result;
    }

    fn line_start(emitter: *const Emitter, offset: u32) u32 {
        assert(offset <= emitter.source.len);

        const before = emitter.source[0..offset];
        const broken_at = std.mem.findScalarLast(u8, before, '\n');
        const start: u32 = if (broken_at) |at| @intCast(at + 1) else 0;

        assert(start <= offset);
        if (start > 0) assert(emitter.source[start - 1] == '\n');

        return start;
    }

    fn verbatim(emitter: *Emitter, position: u32, end: u32) error{Overflow}!void {
        assert(end >= position);
        assert(end < emitter.tokens.len);

        const opening = emitter.region_opening(position, end);

        try emitter.region_blocks(position, opening);

        if (emitter.pending_break) try emitter.break_line(position);

        const offset = emitter.tokens[position].offset;
        const whole = emitter.source[offset..emitter.tokens[end].end()];
        const trimmed = std.mem.trimEnd(u8, whole, "\n");
        const held: Span = .{ .offset = offset, .length = @intCast(trimmed.len) };

        emitter.at_previous = end;
        emitter.line_first = emitter.raw[position];
        emitter.pending_break = trimmed.len < whole.len or emitter.raw[end] == .comment;
        emitter.previous = emitter.raw[end];
        emitter.suppress_space = false;
        emitter.until = end + 1;

        try emitter.document.push(.{ .verbatim = held });
        try emitter.region_blocks(opening, end);
    }

    fn region_opening(emitter: *const Emitter, position: u32, end: u32) u32 {
        assert(position <= end);
        assert(end < emitter.raw.len);

        var scan = position;

        while (scan < end) : (scan += 1) {
            if (!is_layout(emitter.raw[scan + 1])) return scan;
        }

        return position;
    }

    fn region_blocks(emitter: *Emitter, position: u32, end: u32) error{Overflow}!void {
        assert(position <= end);
        assert(end < emitter.tokens.len);

        const held = emitter.line_first;
        const stop = end + 1;
        var scan = position + 1;

        while (scan < stop) : (scan += 1) {
            if (emitter.skip == scan) {
                emitter.skip = null;

                continue;
            }

            switch (emitter.raw[scan]) {
                .indent => {
                    emitter.line_first = emitter.line_opener(scan);

                    try emitter.indented(scan, emitter.column_after(scan));
                },
                .dedent => try emitter.region_blocks_dedent(),
                else => {},
            }
        }

        emitter.line_first = held;
    }

    fn region_blocks_dedent(emitter: *Emitter) error{Overflow}!void {
        assert(emitter.indent <= bracket_depth_max);

        if (emitter.indent == 0) return error.Overflow;

        emitter.indent -= 1;
        emitter.closed = emitter.blocks[emitter.indent];
        emitter.after = emitter.after or emitter.closed;
        emitter.opened = false;

        assert(emitter.indent < bracket_depth_max);

        try emitter.document.push(.dedent);
    }

    pub fn line_opener(emitter: *const Emitter, position: u32) Kind {
        assert(position < emitter.raw.len);

        const at = emitter.line_opener_at(position);

        assert(at <= position);

        return emitter.raw[at];
    }

    pub fn line_opener_at(emitter: *const Emitter, position: u32) u32 {
        assert(position <= emitter.raw.len);

        var scan = position;

        while (scan > 0) {
            scan -= 1;

            const kind = emitter.raw[scan];
            const content = !is_layout(kind) and kind != .comment;
            if (content) break;
        }

        while (scan > 0) : (scan -= 1) {
            const kind = emitter.raw[scan - 1];
            const edge = is_layout(kind) or kind == .comment;
            if (edge) break;
        }

        assert(scan <= position);

        return scan;
    }

    fn fstring(emitter: *Emitter, position: u32) error{Overflow}!void {
        assert(position < emitter.raw.len);
        assert(emitter.raw[position] == .f_string_start);

        const end = emitter.fstring_end(position) orelse position;
        const own_line = emitter.pending_break or emitter.previous == null;

        assert(end >= position);

        try emitter.heading(position, .f_string_start, own_line);

        emitter.starting = own_line;

        try emitter.fstring_parted(position, own_line);
        try emitter.opens_join();

        if (!emitter.formatted.active()) {
            if (interpolated.multiline(emitter, position, end)) {
                return interpolated.opens(emitter, position, end);
            }
        }

        const offset = emitter.tokens[position].offset;
        const held: Span = .{ .offset = offset, .length = emitter.tokens[end].end() - offset };

        emitter.at_previous = end;
        emitter.previous = .f_string_end;
        emitter.suppress_space = false;
        emitter.until = end + 1;

        if (field.respaced(emitter, position, end)) |fitted| {
            return emitter.document.push(.{ .verbatim_arena = fitted });
        }

        if (emitter.relit(held)) |swapped| {
            return emitter.document.push(.{ .verbatim_arena = swapped });
        }

        try emitter.document.push(.{ .verbatim = held });
    }

    fn fstring_parted(emitter: *Emitter, position: u32, own_line: bool) error{Overflow}!void {
        assert(position < emitter.raw.len);
        assert(emitter.depth <= bracket_depth_max);

        const priority = emitter.parting(.f_string_start);
        const kept = emitter.parts(priority);
        const joining = emitter.parted_join(position);

        if (kept) |level| try emitter.ends_element(level);

        const separating = !own_line and
            (joining or kept != null or emitter.spaced(.f_string_start));

        if (separating) {
            const loose: Element = if (kept == null) .space else .line;
            const element: Element = if (joining) .hard_line else loose;

            try emitter.document.push(element);
        }

        if (kept != null) try emitter.starts_element(position, .f_string_start, priority);
    }

    fn hoist(emitter: *Emitter, position: u32) bool {
        assert(position < emitter.raw.len);
        assert(emitter.raw.len == emitter.tokens.len);

        const count: u32 = @intCast(emitter.tokens.len);
        var scan = position;

        while (scan < count) : (scan += 1) {
            const kind = emitter.raw[scan];

            if (kind == .indent) {
                emitter.skip = scan;

                return true;
            }

            const passed = kind == .comment or kind == .newline;
            if (!passed) return false;
        }

        return false;
    }

    fn column_after(emitter: *const Emitter, position: u32) u32 {
        assert(position < emitter.raw.len);
        assert(emitter.raw.len == emitter.tokens.len);

        const count: u32 = @intCast(emitter.tokens.len);
        var scan = position + 1;

        while (scan < count) : (scan += 1) {
            if (is_layout(emitter.raw[scan])) continue;
            return emitter.line_indent(emitter.tokens[scan].offset);
        }

        return 0;
    }

    fn dedents_after(emitter: *const Emitter, position: u32) u32 {
        assert(position < emitter.raw.len);
        assert(emitter.raw.len == emitter.tokens.len);

        const count: u32 = @intCast(emitter.tokens.len);
        var found: u32 = 0;
        var scan = position;

        while (scan < count) : (scan += 1) {
            const kind = emitter.raw[scan];
            const passed = kind == .comment or kind == .newline;
            if (passed) continue;
            if (kind != .dedent) break;

            found += 1;
        }

        assert(found <= scan - position);

        return found;
    }

    fn lower(emitter: *Emitter, position: u32) error{Overflow}!void {
        assert(position < emitter.tokens.len);
        assert(emitter.indent <= bracket_depth_max);

        if (!emitter.heads_line(position)) return;

        const column = emitter.line_indent(emitter.tokens[position].offset);
        var pending = emitter.dedents_after(position) -| emitter.lowered;

        while (pending > 0) : (pending -= 1) {
            if (emitter.indent == 0) break;
            if (column >= emitter.columns[emitter.indent - 1]) break;

            emitter.indent -= 1;
            emitter.closed = emitter.blocks[emitter.indent];
            emitter.after = emitter.after or emitter.closed;
            emitter.lowered += 1;

            try emitter.document.push(.dedent);
        }
    }

    fn indented(emitter: *Emitter, position: u32, column: u32) error{Overflow}!void {
        assert(position < emitter.raw.len);
        assert(emitter.indent <= bracket_depth_max);

        if (emitter.indent == bracket_depth_max) return error.Overflow;
        assert(column < std.math.maxInt(u32));

        const opener = emitter.line_opener_at(position);
        const definition = emitter.opens_definition(opener);

        emitter.blocks[emitter.indent] = definition;
        emitter.functions[emitter.indent] = definition and emitter.raw[opener] != .class_keyword;
        emitter.columns[emitter.indent] = column;
        emitter.indent += 1;
        emitter.opened = true;

        try emitter.document.push(.indent);
    }

    fn follows_an_import(emitter: *const Emitter, position: u32) bool {
        assert(position < emitter.raw.len);
        assert(emitter.line_depth <= bracket_depth_max);

        const kind = emitter.raw[position];
        const line_first = emitter.line_first;
        const importing = line_first == .from_keyword or line_first == .import_keyword;
        if (!importing) return false;
        if (emitter.line_first_at == null) return false;
        if (kind == .from_keyword) return false;
        if (kind == .import_keyword) return false;
        return emitter.line_depth == emitter.indent;
    }

    pub fn continues(emitter: *const Emitter, position: u32) bool {
        assert(position < emitter.raw.len);

        const result = switch (emitter.raw[position]) {
            .elif_keyword, .else_keyword, .except_keyword, .finally_keyword => true,
            else => false,
        };

        if (result) assert(opens_suite(emitter.raw[position]));

        return result;
    }

    fn nests(emitter: *const Emitter) bool {
        assert(emitter.indent <= bracket_depth_max);

        if (emitter.indent == 0) return false;

        const result = !emitter.blocks[emitter.indent - 1];

        if (result) assert(emitter.indent > 0);

        return result;
    }

    pub fn opens_definition(emitter: *const Emitter, position: u32) bool {
        assert(position < emitter.raw.len);

        const kind = emitter.raw[position];
        if (kind == .async_keyword) return emitter.follows_definition(position);

        const result = switch (kind) {
            .at, .class_keyword, .def_keyword => true,
            else => false,
        };

        if (result) assert(kind.is_token());

        return result;
    }

    fn follows_definition(emitter: *const Emitter, position: u32) bool {
        assert(position < emitter.raw.len);
        assert(emitter.raw.len == emitter.tokens.len);

        const count: u32 = @intCast(emitter.tokens.len);
        var scan = position + 1;

        while (scan < count) : (scan += 1) {
            const kind = emitter.raw[scan];
            const content = !is_layout(kind) and kind != .comment;
            if (content) return kind == .def_keyword;
        }

        return false;
    }

    fn mark(emitter: *Emitter, kind: Kind) void {
        assert(kind.is_token());
        assert(emitter.depth <= bracket_depth_max);

        if (kind == .lambda_keyword) {
            emitter.at_lambda = emitter.depth;

            return;
        }

        if (kind != .colon) return;

        if (emitter.at_lambda == emitter.depth) emitter.at_lambda = null;
        if (emitter.depth > 0) emitter.frames[emitter.depth - 1].annotated = true;
    }

    fn magic_of(emitter: *const Emitter, position: u32, call: bool) bool {
        assert(position < emitter.raw.len);
        assert(is_open(emitter.raw[position]));

        const count: u32 = @intCast(emitter.tokens.len);
        const opening = emitter.raw[position];
        var closing: ?Kind = null;
        var commas: u32 = 0;
        var depth: u32 = 0;
        var parameters: u32 = 0;
        var previous: ?Kind = null;
        var scan = position;

        while (scan < count) : (scan += 1) {
            const kind = emitter.raw[scan];

            if (is_open(kind)) {
                depth += 1;
                previous = kind;

                continue;
            }

            if (is_close(kind)) {
                depth -= 1;

                if (depth == 0) {
                    closing = kind;

                    break;
                }

                previous = kind;

                continue;
            }

            if (depth == 1) {
                if (kind == .lambda_keyword) parameters += 1;
                if (kind == .colon) parameters -|= 1;
            }

            const counted = kind == .comma and depth == 1 and parameters == 0;

            if (counted) commas += 1;
            if (!is_layout(kind)) previous = kind;
        }

        const closed = closing orelse return false;
        const line_first = emitter.line_first;
        const imported = line_first == .from_keyword or line_first == .import_keyword;
        const listing = imported or emitter.previous == .with_keyword;
        const tupled = opening == .paren_open and !call and !listing and commas == 1;
        const indexed = opening == .bracket_open and call and commas == 1;

        if (tupled) return false;
        if (indexed) return false;
        return opened_by(closed) == opening and previous == .comma;
    }

    fn complicated(emitter: *const Emitter, position: u32) bool {
        assert(position < emitter.raw.len);
        assert(is_open(emitter.raw[position]));

        const count: u32 = @intCast(emitter.tokens.len);
        var depth: u32 = 0;
        var previous: ?Kind = null;
        var scan = position;

        while (scan < count) : (scan += 1) {
            const kind = emitter.raw[scan];
            if (is_layout(kind)) continue;

            if (is_open(kind)) {
                depth += 1;

                if (depth > 1) return true;

                previous = kind;

                continue;
            }

            if (is_close(kind)) {
                depth -= 1;

                if (depth == 0) return false;

                previous = kind;

                continue;
            }

            if (complicated_kind(kind)) return true;

            const operand = if (previous) |held| ends_operand(held) else false;
            const operated = is_binary(kind) and operand;
            if (operated) return true;

            previous = kind;
        }

        return false;
    }

    fn open(emitter: *Emitter, position: u32, kind: Kind) error{Overflow}!void {
        assert(is_open(kind));
        assert(emitter.depth <= bracket_depth_max);
        assert(position < emitter.tokens.len);

        if (emitter.depth == bracket_depth_max) return emitter.text(position, false);

        emitter.frames[emitter.depth] = emitter.open_frame(position, kind);
        emitter.depth += 1;

        const held = emitter.frames[emitter.depth - 1];
        if (held.hugged) return emitter.text(position, false);

        const riding = emitter.rider(position);
        const separating: Element = if (held.magic or riding != null) .hard_line else .soft_line;
        const defining = emitter.line_first == .async_keyword or emitter.line_first == .def_keyword;
        const widened = kind == .paren_open and emitter.depth == 1 and defining;

        try emitter.document.push(.group_open);

        if (widened) try emitter.document.push(.wide);

        try emitter.text(position, false);

        if (riding) |comment_at| try emitter.rides(comment_at);

        try emitter.document.push(.indent);

        const cap = emitter.frame().priority;
        const sole = emitter.frames[emitter.depth - 1].sole;
        const inner = elided.undoubled(emitter, position, held.call);

        if (sole) {
            try emitter.document.push(separating);

            return emitter.starts_element(inner, kind, cap);
        }

        if (held.magic) {
            try emitter.document.push(.group_open);
            try emitter.document.push(separating);
        } else {
            try emitter.document.push(separating);
            try emitter.document.push(.group_open);
        }

        try emitter.starts_element(inner, kind, cap);
    }

    fn open_frame(emitter: *const Emitter, position: u32, kind: Kind) Frame {
        assert(is_open(kind));
        assert(emitter.depth < bracket_depth_max);
        assert(position < emitter.tokens.len);

        const fresh = emitter.starting and emitter.depth == 0 and emitter.elisions == 0;
        const operand = if (emitter.previous) |previous| ends_operand(previous) else false;

        const softened = emitter.soft_keyword() and
            onset.soft_header(emitter, emitter.at_previous.?);

        const subscripted = kind == .bracket_open and emitter.parameterised();
        const call = !fresh and operand and !softened and !subscripted;
        const magic_source = emitter.magic_of(position, call);
        const asynchronous = emitter.line_first == .async_keyword;
        const defined = asynchronous and emitter.next_kind(emitter.line_first_at.?) == .def_keyword;

        const parameters = call and kind == .paren_open and emitter.depth == 0 and
            (defined or emitter.line_first == .def_keyword);

        const priority = if (parameters)
            priority_comma
        else
            emitter.priority_of(elided.undoubled(emitter, position, call));

        const headed = emitter.line_first == .def_keyword or emitter.line_first == .from_keyword;
        const owing = defined or headed or emitter.line_first == .import_keyword;
        const leading = kind == .paren_open and emitter.depth == 0;
        var held: Frame = .new();

        held.call = call;

        held.complex = kind == .bracket_open and call and
            slice.element_complex(emitter, position + 1);

        held.owes = leading and owing and !onset.annotates_return(emitter, position);
        held.kind = kind;
        held.magic = emitter.magic_trailing_comma and magic_source;
        held.hugged = emitter.hugs_literal(position, call) or emitter.hollow(position);
        held.magic_source = magic_source;
        held.priority = priority;
        held.sole = !call and priority == priority_comma and emitter.listed(position);

        assert(held.level_count == 0);

        return held;
    }

    fn enjoin(emitter: *Emitter, position: u32) void {
        assert(position < emitter.raw.len);
        if (emitter.concat_span.length > 0) assert(emitter.concat_at != null);

        const kind = emitter.raw[position];
        const strung = kind == .f_string_start or kind == .string_bytes or kind == .string_plain;
        const ending = emitter.previous == .f_string_end or emitter.previous == .string_bytes;
        const continued = ending or emitter.previous == .string_plain;

        if (!strung) return;
        if (continued) return;
        if (emitter.concat_at != null) return;
        if (docstrings.documents(emitter, position)) return;
        if (!emitter.chain_joins(position)) return;

        const end = emitter.joinable(position) orelse return;
        const held = emitter.joined(position, end) orelse return;

        assert(end > position);

        emitter.concat_at = end;
        emitter.concat_span = held;
    }

    fn chain_joins(emitter: *const Emitter, position: u32) bool {
        assert(position < emitter.raw.len);
        assert(is_string_start(emitter.raw[position]));

        const behind = emitter.concat_behind(position);

        if (!behind) {
            if (!emitter.concat_ahead(position)) return true;
        }

        const start = emitter.chain_edge(position, false) orelse return false;
        const stop = emitter.chain_edge(position, true) orelse return false;

        if (!behind) {
            if (emitter.depth == 0) return true;
        }

        const column = (emitter.indent + emitter.depth) * emitter.indent_width;
        const width = emitter.measured(start, stop) -| emitter.chain_joints(start, stop) * 3;
        const trailed: u32 = @intFromBool(emitter.next_kind(stop) == .comma);

        return column + width + trailed <= emitter.line_width;
    }

    fn concat_behind(emitter: *const Emitter, position: u32) bool {
        assert(position < emitter.raw.len);
        assert(is_string_start(emitter.raw[position]));

        const operator = emitter.part_before(position) orelse return false;
        if (!operates(emitter.raw[operator])) return false;

        const before = emitter.part_before(operator) orelse return false;
        return ends_operand(emitter.raw[before]);
    }

    fn concat_ahead(emitter: *const Emitter, position: u32) bool {
        assert(position < emitter.raw.len);
        assert(is_string_start(emitter.raw[position]));

        const end = emitter.concat_end(position) orelse return false;
        const after = emitter.part_after(end) orelse return false;

        return operates(emitter.raw[after]);
    }

    pub fn part_after(emitter: *const Emitter, position: u32) ?u32 {
        assert(position < emitter.tokens.len);
        assert(emitter.tokens.len == emitter.raw.len);

        const count: u32 = @intCast(emitter.tokens.len);
        var scan = position;

        for (position..count) |_| {
            const held = emitter.next_token(scan, count) orelse return null;

            assert(held > scan);

            if (emitter.raw[held] != .comment) return held;

            scan = held;
        }

        return null;
    }

    fn chain_trails(emitter: *const Emitter, position: u32) bool {
        assert(position < emitter.tokens.len);
        assert(emitter.raw[position] == .comment);

        const after = emitter.part_after(position) orelse return true;
        const kind = emitter.raw[after];

        return is_close(kind) or stops_chain(kind);
    }

    fn chain_edge(emitter: *const Emitter, position: u32, forward: bool) ?u32 {
        assert(position < emitter.raw.len);
        assert(emitter.raw.len == emitter.tokens.len);

        const count: u32 = @intCast(emitter.tokens.len);
        var depth: u32 = 0;
        var edge = position;
        var scan = position;

        for (0..count) |_| {
            const next = if (forward) scan + 1 else scan -% 1;
            if (next >= count) return edge;

            scan = next;

            const kind = emitter.raw[scan];
            const inward = if (forward) is_open(kind) else is_close(kind);
            const outward = if (forward) is_close(kind) else is_open(kind);

            if (kind == .comment) {
                if (depth > 0) continue;

                if (forward) {
                    if (emitter.chain_trails(scan)) return edge;
                }

                return null;
            }

            if (inward) depth += 1;

            if (outward) {
                if (depth == 0) return edge;

                depth -= 1;
            }

            if (depth == 0) {
                if (stops_chain(kind)) return edge;
            }

            edge = scan;
        }

        return edge;
    }

    fn chain_joints(emitter: *const Emitter, start: u32, stop: u32) u32 {
        assert(start <= stop);
        assert(stop < emitter.raw.len);

        var joints: u32 = 0;
        var prior: ?Kind = null;
        var scan = start;

        while (scan <= stop) : (scan += 1) {
            const kind = emitter.raw[scan];
            if (is_layout(kind)) continue;

            const pieced = prior != null and kind_joined(prior.?) and is_string_start(kind);

            joints += @intFromBool(pieced);
            prior = kind;

            if (kind == .f_string_start) {
                scan = emitter.fstring_end(scan) orelse return joints;
                prior = .f_string_end;
            }
        }

        return joints;
    }

    fn opens_join(emitter: *Emitter) error{Overflow}!void {
        assert(emitter.depth <= bracket_depth_max);

        if (emitter.concat_span.length == 0) return;

        const count: u32 = @intCast(emitter.tokens.len);
        const held = emitter.concat_span;
        const concat_at = emitter.concat_at.?;
        const hugs = emitter.joins_hug(emitter.at_previous, concat_at);
        const tail = emitter.hug_tail(concat_at);
        const tailed = hugs and tail != concat_at;
        const breaks = tailed and !emitter.hug_fits(emitter.at_previous.?, concat_at);

        assert(tail >= concat_at);

        if (breaks) {
            emitter.hug_break = emitter.next_token(concat_at, count);
            emitter.hug_depth = emitter.depth;
            emitter.hug_end = tail;
        }

        emitter.concat_span = .empty;

        if (hugs) try emitter.document.push(.hugged);

        try emitter.document.push(.group_open);
        try emitter.document.push(.{ .joined = held });
    }

    fn joins_hug(emitter: *const Emitter, position: ?u32, end: ?u32) bool {
        assert(emitter.depth <= bracket_depth_max);
        assert(emitter.indent <= bracket_depth_max);
        if (position) |held| assert(held < emitter.tokens.len);

        const binary = if (emitter.previous) |previous| is_binary(previous) else false;
        if (!binary) return false;
        if (end == null) return false;

        const at = position.?;
        const column = (emitter.indent + emitter.depth) * emitter.indent_width;
        const start = emitter.element_start(at);
        const stop = emitter.part_end(at).?;
        const width = if (start) |held| emitter.measured(held, stop) else 0;

        return column + width <= emitter.line_width;
    }

    fn hug_breaks(emitter: *const Emitter, position: u32) bool {
        assert(position < emitter.raw.len);
        assert(emitter.depth <= bracket_depth_max);

        const hug_break = emitter.hug_break orelse return false;

        assert(emitter.hug_end != null);

        if (position < hug_break) return false;
        if (position > emitter.hug_end.?) return false;
        return emitter.depth == emitter.hug_depth;
    }

    fn hug_fits(emitter: *const Emitter, position: u32, end: u32) bool {
        assert(position <= end);
        assert(end < emitter.raw.len);

        const column = (emitter.indent + emitter.depth) * emitter.indent_width;
        const last = emitter.part_last(position, end);

        return column + emitter.measured(last, emitter.hug_tail(end)) <= emitter.line_width;
    }

    fn part_last(emitter: *const Emitter, position: u32, end: u32) u32 {
        assert(position <= end);
        assert(end < emitter.tokens.len);

        const stop = end + 1;
        var held = position;
        var scan = position;

        while (scan < stop) {
            const kind = emitter.raw[scan];
            const skipped = is_layout(kind) or kind == .comment;

            if (skipped) {
                scan += 1;

                continue;
            }

            held = scan;
            scan = emitter.part_end(scan).? + 1;
        }

        assert(held <= end);

        return held;
    }

    fn hug_tail(emitter: *const Emitter, end: u32) u32 {
        assert(end < emitter.raw.len);
        assert(emitter.raw.len == emitter.tokens.len);

        const count: u32 = @intCast(emitter.tokens.len);
        var depth: u32 = 0;
        var held = end;
        var scan = end + 1;

        while (scan < count) : (scan += 1) {
            const kind = emitter.raw[scan];
            const bounded = depth == 0 and (kind == .comma or is_close(kind));

            if (ends_line(kind)) break;
            if (bounded) break;

            if (is_open(kind)) depth += 1;
            if (is_close(kind)) depth -= 1;

            const content = !is_layout(kind) and kind != .comment;

            if (content) held = scan;
        }

        assert(held >= end);

        return held;
    }

    fn unjoin(emitter: *Emitter) error{Overflow}!void {
        if (emitter.concat_span.length > 0) assert(emitter.concat_at != null);

        if (emitter.concat_at == null) return;

        emitter.concat_at = null;

        if (emitter.concat_span.length > 0) {
            emitter.concat_span = .empty;

            return;
        }

        assert(emitter.concat_span.length == 0);

        try emitter.document.push(.group_close);
        try emitter.opens_deferred(0);
    }

    pub fn concat_end(emitter: *const Emitter, position: u32) ?u32 {
        assert(position < emitter.raw.len);
        assert(emitter.raw.len == emitter.tokens.len);

        const count: u32 = @intCast(emitter.tokens.len);
        var end: ?u32 = null;
        var pieces: u32 = 0;
        var scan = position;

        while (scan < count) {
            const kind = emitter.raw[scan];

            if (kind == .newline) {
                scan += 1;

                continue;
            }

            const held = switch (kind) {
                .f_string_start => emitter.fstring_end(scan) orelse break,
                .string_bytes, .string_plain => scan,
                else => break,
            };

            end = held;
            pieces += 1;
            scan = held + 1;
        }

        if (pieces < 2) return null;

        assert(end.? > position);

        return end;
    }

    pub fn fstring_end(emitter: *const Emitter, position: u32) ?u32 {
        assert(position < emitter.raw.len);
        assert(emitter.raw[position] == .f_string_start);

        const count: u32 = @intCast(emitter.tokens.len);
        var depth: u32 = 0;
        var scan = position;

        while (scan < count) : (scan += 1) {
            const kind = emitter.raw[scan];

            if (kind == .f_string_start) depth += 1;

            if (kind == .f_string_end) {
                depth -= 1;

                if (depth == 0) return scan;
            }
        }

        return null;
    }

    fn joined(emitter: *Emitter, position: u32, end: u32) ?Span {
        assert(position < end);
        assert(end < emitter.raw.len);

        const marks = emitter.marks_of(position, end) orelse return null;
        return emitter.written_join(position, end, marks);
    }

    pub fn marks_of(emitter: *const Emitter, position: u32, end: u32) ?JoinMarks {
        assert(position <= end);
        assert(end < emitter.raw.len);

        var marks: JoinMarks = .{ .bytes = false, .format = false, .template = false };
        var plain = false;
        var scan = position;

        while (scan <= end) {
            const held = emitter.part(scan) orelse return null;
            const spelling = held.text(emitter.source);
            const prefix = spelling[0..prefix_of(spelling)];
            const bytes = std.mem.findAny(u8, prefix, "Bb") != null;

            marks.bytes = marks.bytes or bytes;
            marks.format = marks.format or std.mem.findAny(u8, prefix, "FTft") != null;
            marks.template = marks.template or std.mem.findAny(u8, prefix, "Tt") != null;
            plain = plain or !bytes;
            scan = emitter.part_end(scan).? + 1;
        }

        if (marks.bytes) {
            if (plain) return null;
        }

        return marks;
    }

    pub fn joins(emitter: *const Emitter, position: u32) bool {
        assert(position < emitter.raw.len);
        assert(is_string_start(emitter.raw[position]));

        if (docstrings.documents(emitter, position)) return false;
        if (!emitter.chain_joins(position)) return false;
        return emitter.joinable(position) != null;
    }

    fn joinable(emitter: *const Emitter, position: u32) ?u32 {
        assert(position < emitter.raw.len);
        assert(emitter.raw.len == emitter.tokens.len);

        const end = emitter.concat_end(position) orelse return null;
        const marks = emitter.marks_of(position, end) orelse return null;

        assert(end > position);

        if (concat.commented(emitter, position, end)) return null;
        if (concat.trailed(emitter, position, end)) return null;
        if (emitter.join_quote(position, end, marks.format) == null) return null;
        if (!marks.format) return end;
        if (!emitter.joinable_formats(position, end)) return null;
        return end;
    }

    fn joinable_formats(emitter: *const Emitter, position: u32, end: u32) bool {
        assert(position < end);
        assert(end < emitter.raw.len);

        var scan = position;

        while (scan <= end) {
            const held = emitter.part(scan) orelse return false;
            const spelling = held.text(emitter.source);
            const at = prefix_of(spelling);
            const body = spelling[at + 1 .. spelling.len - 1];
            const formats = std.mem.findAny(u8, spelling[0..at], "FTft") != null;
            const braced = std.mem.findAny(u8, body, "{}") != null;
            const stray = !formats and braced;
            if (stray) return false;

            scan = emitter.part_end(scan).? + 1;
        }

        return true;
    }

    fn part(emitter: *const Emitter, position: u32) ?Span {
        assert(position < emitter.raw.len);
        assert(emitter.raw.len == emitter.tokens.len);

        const end = emitter.part_end(position).?;
        const offset = emitter.tokens[position].offset;
        const held: Span = .{ .offset = offset, .length = emitter.tokens[end].end() - offset };
        const spelling = held.text(emitter.source);
        const at = prefix_of(spelling);
        const rest = spelling[at..];
        const raw = std.mem.findAny(u8, spelling[0..at], "Rr") != null;
        const tripled_double = std.mem.startsWith(u8, rest, triple_double);
        const tripled_single = std.mem.startsWith(u8, rest, triple_single);

        if (raw) return null;
        if (tripled_double) return null;
        if (tripled_single) return null;
        if (rest.len < 2) return null;

        assert(end >= position);

        return held;
    }

    pub fn join_quote(emitter: *const Emitter, position: u32, end: u32, format: bool) ?u8 {
        assert(position <= end);
        assert(end < emitter.raw.len);

        const wanted: u8 = switch (emitter.quote) {
            .single => '\'',
            .double, .preserve => '"',
        };

        const other = other_quote(wanted);
        var alone: u32 = 0;
        var held: u32 = 0;
        var scan = position;

        while (scan <= end) {
            _ = emitter.part(scan) orelse return null;

            alone += emitter.part_escapes(scan, other);
            held += emitter.part_escapes(scan, wanted);
            scan = emitter.part_end(scan).? + 1;
        }

        const quote = if (alone < held) other else wanted;
        const swaps = !format or emitter.join_swaps(position, end, quote);
        if (!swaps) return null;
        return quote;
    }

    fn part_escapes(emitter: *const Emitter, position: u32, quote: u8) u32 {
        assert(position < emitter.raw.len);
        assert(quote != 0);

        const end = emitter.part_end(position).?;

        if (emitter.raw[position] != .f_string_start) {
            const piece = emitter.tokens[position];
            const spelling = emitter.source[piece.offset..piece.end()];
            const at = prefix_of(spelling);

            assert(escapes_of(spelling[at + 1 .. spelling.len - 1], quote) <= emitter.tokens.len);

            return escapes_of(spelling[at + 1 .. spelling.len - 1], quote);
        }

        var depth: u32 = 0;
        var found: u32 = 0;
        var scan = position;

        while (scan <= end) : (scan += 1) {
            const kind = emitter.raw[scan];

            depth += @intFromBool(kind == .f_string_start);

            const counted = kind == .f_string_middle and depth == 1;

            if (counted) {
                const middle = emitter.tokens[scan];

                found += escapes_of(emitter.source[middle.offset..middle.end()], quote);
            }

            depth -= @intFromBool(kind == .f_string_end);
        }

        assert(depth == 0);

        return found;
    }

    fn join_swaps(emitter: *const Emitter, position: u32, end: u32, quote: u8) bool {
        assert(position <= end);
        assert(end < emitter.raw.len);
        assert(quote == '"' or quote == '\'');

        var scan = position;

        while (scan <= end) {
            const piece = emitter.part(scan) orelse return false;
            const spelling = piece.text(emitter.source);
            const at = prefix_of(spelling);
            const plain = emitter.raw[scan] != .f_string_start;
            const swapped = spelling[at] != quote;
            const body = spelling[at + 1 .. spelling.len - 1];
            const clashes = std.mem.findScalar(u8, body, quote) != null;
            const refused = plain and swapped and clashes;
            if (refused) return false;

            scan = emitter.part_end(scan).? + 1;
        }

        return true;
    }

    pub fn part_end(emitter: *const Emitter, position: u32) ?u32 {
        assert(position < emitter.raw.len);

        if (emitter.raw[position] == .f_string_start) return emitter.fstring_end(position);

        assert(position < emitter.tokens.len);

        return position;
    }

    fn written_join(emitter: *Emitter, position: u32, end: u32, marks: JoinMarks) ?Span {
        assert(position <= end);
        assert(end < emitter.raw.len);
        if (marks.template) assert(marks.format);

        const offset = emitter.arena.count();
        const prefixed = emitter.written_join_prefix(marks);
        const quote = emitter.join_quote(position, end, marks.format) orelse return null;

        const complete = prefixed and
            emitter.written_join_quoted(position, end, marks.format, quote);

        if (!complete) {
            emitter.arena.truncate(offset);

            return null;
        }

        assert(emitter.arena.count() > offset);

        return .{ .offset = offset, .length = emitter.arena.count() - offset };
    }

    fn written_join_prefix(emitter: *Emitter, marks: JoinMarks) bool {
        if (marks.template) assert(marks.format);

        const offset = emitter.arena.count();
        const letter = if (marks.template) "t" else "f";

        if (marks.bytes) emitter.arena.push("b") catch return false;
        if (marks.format) emitter.arena.push(letter) catch return false;

        assert(emitter.arena.count() >= offset);
        assert(emitter.arena.count() - offset <= 2);

        return true;
    }

    fn written_join_quoted(
        emitter: *Emitter,
        position: u32,
        end: u32,
        format: bool,
        quote: u8,
    ) bool {
        assert(position <= end);
        assert(quote != 0);

        emitter.arena.push_byte(quote) catch return false;

        var scan = position;

        while (scan <= end) {
            const stop = emitter.part_end(scan).?;

            if (emitter.raw[scan] == .f_string_start) {
                const refit = field.refielded(emitter, scan, stop, quote) catch false;
                if (!refit) return false;

                scan = stop + 1;

                continue;
            }

            const held = emitter.part(scan) orelse unreachable;
            const spelling = held.text(emitter.source);
            const at = prefix_of(spelling);
            const body = spelling[at + 1 .. spelling.len - 1];
            const template = std.mem.findAny(u8, spelling[0..at], "Tt") != null;
            const raw = std.mem.findAny(u8, spelling[0..at], "Rr") != null;
            const fielded = template and !raw and std.mem.findAny(u8, body, "\\\"'") == null;
            const braced = format and !fielded and std.mem.findAny(u8, body, "{}") != null;
            const unicode = std.mem.findAny(u8, spelling[0..at], "Bb") == null;

            if (braced) return false;

            quoted_body(emitter.arena, body, quote, unicode) catch return false;
            scan = stop + 1;
        }

        emitter.arena.push_byte(quote) catch return false;

        return true;
    }

    fn listed(emitter: *const Emitter, position: u32) bool {
        assert(position < emitter.raw.len);
        assert(is_open(emitter.raw[position]));

        const count: u32 = @intCast(emitter.tokens.len);
        var commas: u32 = 0;
        var depth: u32 = 0;
        var previous: ?Kind = null;
        var scan = position;

        while (scan < count) : (scan += 1) {
            const kind = emitter.raw[scan];

            if (is_open(kind)) depth += 1;

            if (is_close(kind)) {
                depth -= 1;

                if (depth == 0) return commas > @intFromBool(previous == .comma);
            }

            const counted = kind == .comma and depth == 1;
            const content = !is_layout(kind) and kind != .comment;

            if (counted) commas += 1;
            if (content) previous = kind;
        }

        return false;
    }

    fn hollow(emitter: *const Emitter, position: u32) bool {
        assert(position < emitter.raw.len);
        assert(is_open(emitter.raw[position]));

        const count: u32 = @intCast(emitter.tokens.len);
        var scan = position + 1;

        while (scan < count) : (scan += 1) {
            if (!is_layout(emitter.raw[scan])) break;
        }

        if (scan == count) return false;
        return is_close(emitter.raw[scan]);
    }

    fn hugs_literal(emitter: *const Emitter, position: u32, call: bool) bool {
        assert(position < emitter.raw.len);
        assert(is_open(emitter.raw[position]));

        if (!call) return false;
        if (emitter.raw[position] != .paren_open) return false;

        const count: u32 = @intCast(emitter.tokens.len);
        var scan = position + 1;

        while (scan < count) : (scan += 1) {
            if (!is_layout(emitter.raw[scan])) break;
        }

        if (scan >= count) return false;

        const opened = emitter.tokens[position].end();
        const starts = emitter.tokens[scan].offset;
        const between = if (starts > opened) emitter.source[opened..starts] else "";
        if (std.mem.findScalar(u8, between, '\n') != null) return false;

        const end = emitter.part_end(scan) orelse return false;
        if (end >= count) return false;

        const kind = emitter.raw[scan];
        const stringed = kind == .f_string_start or kind == .string_bytes or kind == .string_plain;
        const literal = emitter.source[starts..emitter.tokens[end].end()];
        const quoted = literal[prefix_of(literal)..];

        const tripled = std.mem.startsWith(u8, quoted, triple_double) or
            std.mem.startsWith(u8, quoted, triple_single);

        if (!stringed) return false;
        if (!tripled) return false;
        if (std.mem.findScalar(u8, literal, '\n') == null) return false;

        if (kind == .f_string_start) {
            if (!interpolated.lined(emitter, scan, end)) return false;
        }

        var after = end + 1;

        while (after < count) : (after += 1) {
            if (!is_layout(emitter.raw[after])) break;
        }

        if (after >= count) return false;
        return is_close(emitter.raw[after]);
    }

    fn priority_of(emitter: *const Emitter, position: u32) u8 {
        assert(position < emitter.raw.len);
        assert(is_open(emitter.raw[position]));

        const count: u32 = @intCast(emitter.tokens.len);
        var depth: u32 = 0;
        var found: u8 = 0;
        var held: Splits = .new();
        var previous: ?Kind = null;
        var repeats: u32 = 0;
        var scan = position;

        while (scan < count) : (scan += 1) {
            const kind = emitter.raw[scan];
            const skipped = is_layout(kind) or kind == .comment;
            if (skipped) continue;

            if (is_close(kind)) {
                depth -= 1;

                if (depth == 0) break;
            }

            if (depth == 1) {
                const priority = held.step(kind, previous);

                if (priority > found) {
                    found = priority;
                    repeats = 0;
                }

                repeats += @intFromBool(priority > 0 and priority == found);
            }

            depth += @intFromBool(is_open(kind));
            previous = kind;
        }

        const dotted = found == priority_dot and repeats < 2;
        if (dotted) return 0;

        assert(found <= priority_comprehension);

        return found;
    }

    pub fn priority_between(emitter: *const Emitter, from: u32, end: u32) u8 {
        assert(from <= end);
        assert(end <= emitter.tokens.len);

        var depth: u32 = 0;
        var found: u8 = 0;
        var held: Splits = .new();
        var previous: ?Kind = null;
        var repeats: u32 = 0;

        for (from..end) |scan| {
            const kind = emitter.raw[scan];
            const skipped = is_layout(kind) or kind == .comment;
            if (skipped) continue;

            if (is_close(kind)) depth -|= 1;

            if (depth == 0) {
                const priority = held.step(kind, previous);

                if (priority > found) {
                    found = priority;
                    repeats = 0;
                }

                repeats += @intFromBool(priority > 0 and priority == found);
            }

            depth += @intFromBool(is_open(kind));
            previous = kind;
        }

        const dotted = found == priority_dot and repeats < 2;
        if (dotted) return 0;

        assert(found <= priority_comprehension);

        return found;
    }

    fn priority_of_element(emitter: *const Emitter, position: u32, previous: ?Kind, cap: u8) u8 {
        assert(position <= emitter.raw.len);
        assert(cap > 0);
        if (previous) |held| assert(held.is_token());

        const count: u32 = @intCast(emitter.tokens.len);
        const braced = emitter.frame().kind == .brace_open;
        const defaults = emitter.parametric();
        var annotating = emitter.frame().annotated;
        var depth: u32 = 0;
        var found: u8 = 0;
        var held = emitter.frame().splits;
        var last = previous;
        var repeats: u32 = 0;
        var scan = position;

        while (scan < count) : (scan += 1) {
            const kind = emitter.raw[scan];
            const skipped = is_layout(kind) or kind == .comment;

            if (ends_line(kind)) break;
            if (skipped) continue;

            if (is_close(kind)) {
                if (depth == 0) break;

                depth -= 1;
            }

            if (depth == 0) {
                if (kind == .colon) annotating = true;

                const defaulted = defaults and annotating and kind == .equal;
                if (defaulted) break;

                const priority = held.step(kind, last);
                if (priority >= cap) break;

                const entry = kind == .colon and braced and emitter.entered(scan);

                if (entry) {
                    found = 0;
                    repeats = 0;
                }

                if (priority > found) {
                    found = priority;
                    repeats = 0;
                }

                repeats += @intFromBool(priority > 0 and priority == found);
            }

            depth += @intFromBool(is_open(kind));
            last = kind;
        }

        const dotted = found == priority_dot and repeats < 2;
        if (dotted) return 0;

        assert(found < cap);

        return found;
    }

    pub fn ends_element(emitter: *Emitter, kept: u32) error{Overflow}!void {
        assert(kept <= element_depth_max);
        assert(emitter.depth <= bracket_depth_max);

        const idle = emitter.depth == 0 and emitter.wrap == null;
        if (idle) return;

        while (emitter.frame().level_count > kept) {
            var held = emitter.frame();

            held.level_count -= 1;

            const closes = held.group_count > held.level_count and emitter.concat_at == null;

            held.group_count -= @intFromBool(closes);

            emitter.set_frame(&held);

            if (closes) try emitter.document.push(.group_close);
        }

        assert(emitter.frame().level_count <= kept);
    }

    fn comments_trail(emitter: *const Emitter, position: u32) bool {
        assert(position < emitter.raw.len);
        assert(emitter.raw.len == emitter.tokens.len);

        const count: u32 = @intCast(emitter.tokens.len);
        var found = false;
        var scan = position + 1;

        while (scan < count) : (scan += 1) {
            const kind = emitter.raw[scan];
            if (is_layout(kind)) continue;
            if (kind != .comment) break;
            if (!emitter.heads_line(scan)) break;

            const parted_run = found and emitter.blanked_above(scan);
            if (parted_run) return true;

            found = true;
        }

        if (!found) return false;
        if (scan == count) return true;
        return emitter.blanked_above(scan);
    }

    fn blanked_above(emitter: *const Emitter, position: u32) bool {
        assert(position < emitter.tokens.len);

        const offset = emitter.tokens[position].offset;
        const blanks = emitter.blanks_before(position, offset);

        assert(blanks <= offset);

        return blanks > 0;
    }

    fn comments_from(emitter: *const Emitter, from: u32) bool {
        assert(from <= emitter.raw.len);
        assert(emitter.raw.len == emitter.tokens.len);

        const count: u32 = @intCast(emitter.tokens.len);
        var scan = from;

        while (scan < count) : (scan += 1) {
            const kind = emitter.raw[scan];
            if (kind == .comment) return emitter.heads_line(scan);
            if (!is_layout(kind)) return false;
        }

        return false;
    }

    fn hollows(emitter: *const Emitter, position: u32, own_line: bool) bool {
        assert(position < emitter.raw.len);
        assert(emitter.raw[position] == .comment);

        const inside = if (emitter.previous) |previous| is_open(previous) else false;
        if (inside) return true;
        if (own_line) return false;
        if (emitter.heads_line(position)) return false;

        const count: u32 = @intCast(emitter.tokens.len);
        var scan = position + 1;

        while (scan < count) : (scan += 1) {
            const kind = emitter.raw[scan];
            const skipped = kind == .comment or is_layout(kind);
            if (skipped) continue;
            return is_close(kind);
        }

        return false;
    }

    fn closes_deferred(emitter: *Emitter, hollowed: bool, interrupted: u8) error{Overflow}!void {
        assert(emitter.depth <= bracket_depth_max);

        const idle = emitter.depth == 0 and emitter.wrap == null;
        if (idle) return;

        while (emitter.frame().group_count > 0) {
            var inner = emitter.frame();
            const level = inner.levels[inner.group_count - 1];

            inner.group_count -= 1;

            emitter.set_frame(&inner);

            if (interrupted > 0) {
                if (level >= interrupted) try emitter.document.push(.broken);
            }

            try emitter.document.push(.group_close);
        }

        var held = emitter.frame();
        const spread = held.priority == priority_comma or held.priority == priority_comprehension;
        const kept = !hollowed or emitter.depth == 0 or held.sole or held.hollow or spread;

        assert(held.group_count == 0);

        if (kept) return;

        held.hollow = true;

        emitter.set_frame(&held);

        try emitter.document.push(.group_close);
    }

    fn interrupting(emitter: *const Emitter, position: u32) u8 {
        assert(position < emitter.tokens.len);
        assert(emitter.tokens.len == emitter.raw.len);

        const linking = operates(emitter.raw[position]) or emitter.raw[position] == .dot;

        if (linking) {
            const prior = emitter.prior_token(position, 0);
            const noted = if (prior) |at| emitter.raw[at] == .comment else false;
            const pending = if (emitter.pending_word) |word| word.position == position else false;
            const separated = noted or pending;

            if (separated) {
                const operand = emitter.part_before(position) orelse return 0;
                return kind_parted(emitter.raw[position], emitter.raw[operand]);
            }
        }

        const operator = emitter.part_before(position) orelse return 0;
        const kind = emitter.raw[operator];
        if (!operates(kind)) return 0;

        const before = emitter.part_before(operator) orelse return 0;
        return kind_parted(kind, emitter.raw[before]);
    }

    fn opens_deferred(emitter: *Emitter, interrupted: u8) error{Overflow}!void {
        assert(emitter.depth <= bracket_depth_max);

        const idle = emitter.depth == 0 and emitter.wrap == null;
        if (idle) return;

        var emptied = emitter.frame();
        const reopens = emitter.depth > 0 and emptied.hollow;

        if (reopens) {
            emptied.hollow = false;

            emitter.set_frame(&emptied);

            try emitter.document.push(.group_open);
        }

        while (emitter.frame().group_count > emitter.frame().level_count) {
            var held = emitter.frame();

            held.group_count -= 1;

            emitter.set_frame(&held);

            try emitter.document.push(.group_close);
        }

        while (emitter.frame().group_count < emitter.frame().level_count) {
            var held = emitter.frame();

            held.group_count += 1;

            emitter.set_frame(&held);

            try emitter.document.push(.group_open);

            const level = held.levels[held.group_count - 1];

            if (interrupted > 0) {
                if (level >= interrupted) try emitter.document.push(.broken);
            }
        }

        assert(emitter.frame().group_count == emitter.frame().level_count);
    }

    pub fn starts_element(
        emitter: *Emitter,
        position: u32,
        kind: Kind,
        cap: u8,
    ) error{Overflow}!void {
        assert(position < emitter.raw.len);
        assert(kind.is_token());
        assert(cap <= priority_comprehension);

        return emitter.starts_element_from(position + 1, kind, cap);
    }

    fn starts_element_from(
        emitter: *Emitter,
        from: u32,
        previous: ?Kind,
        cap: u8,
    ) error{Overflow}!void {
        assert(from <= emitter.raw.len);
        assert(emitter.depth <= bracket_depth_max);
        if (previous) |held| assert(held.is_token());
        assert(cap <= priority_comprehension);

        const idle = emitter.depth == 0 and emitter.wrap == null;
        if (idle) return;

        var held = cap;

        while (held > 0) {
            const priority = emitter.priority_of_element(from, previous, held);
            var current = emitter.frame();
            const at = current.level_count;

            if (priority == 0) break;
            if (at == element_depth_max) break;

            assert(priority < held);

            current.levels[at] = priority;
            current.level_count = at + 1;

            const opens = emitter.concat_at == null and !emitter.comments_from(from);

            if (opens) current.group_count = at + 1;

            emitter.set_frame(&current);

            if (opens) try emitter.document.push(.group_open);

            held = priority;
        }
    }

    fn inlined(emitter: *Emitter, position: u32) error{Overflow}!void {
        assert(position < emitter.tokens.len);
        assert(emitter.raw[position] == .colon);

        const spacing = emitter.spaced(.colon);

        try emitter.text(position, spacing);

        const column = emitter.line_indent(emitter.tokens[position].offset);

        emitter.@"inline" += 1;
        emitter.pending_break = true;

        try emitter.indented(position, column + emitter.indent_width);
    }

    fn comment(emitter: *Emitter, position: u32, own_line: bool) error{Overflow}!void {
        assert(position < emitter.raw.len);
        assert(emitter.raw[position] == .comment);

        const standalone = !own_line and emitter.heads_line(position);
        const alone = own_line or standalone;
        const held = emitter.frame();

        const ending = !own_line and emitter.depth > 0 and
            emitter.separates_closing(position, held.kind);

        const sliced = ending and held.kind == .bracket_open and held.call;
        const closing = ending and (standalone or sliced);

        if (closing) try emitter.closes_early(sliced);

        if (!own_line) {
            if (!sliced) try emitter.separates(position);
        }

        const lined = standalone and !emitter.parted();

        if (lined) try emitter.document.push(.hard_line);

        if (alone) {
            try emitter.text(position, false);
        } else {
            const gap_span = emitter.document.literal_span(emitter.literals.gap);
            const lexeme = emitter.tokens[position];
            const marked = pragmatic(emitter.source[lexeme.offset..lexeme.end()]);

            if (marked) try emitter.document.push(.pragma);

            try emitter.document.push(.{ .text = .{ .source = .literal, .span = gap_span } });
            try emitter.text(position, false);
        }

        emitter.pending_break = true;
    }

    fn closes_early(emitter: *Emitter, sliced: bool) error{Overflow}!void {
        assert(emitter.depth > 0);
        assert(emitter.depth <= bracket_depth_max);

        try emitter.ends_element(0);

        const held = emitter.frame();

        const grouped = !held.sole and !held.hollow and !held.hugged and !held.commented and
            (sliced or !held.commas);

        if (!grouped) return;

        emitter.frames[emitter.depth - 1].commented = true;

        try emitter.document.push(.group_close);
    }

    fn separates(emitter: *Emitter, position: u32) error{Overflow}!void {
        assert(position < emitter.raw.len);
        assert(emitter.depth <= bracket_depth_max);

        if (emitter.depth == 0) return;

        const held = emitter.frame();
        const prior = emitter.prior_token(position, 0);
        const commented_prior = if (prior) |at| emitter.raw[at] == .comment else false;
        const bare = !held.commas and !held.owes;
        const exempt = held.hugged or held.trailed or emitter.previous == .comma;
        if (exempt) return;
        if (commented_prior) return;
        if (bare) return;
        if (!emitter.separates_closing(position, held.kind)) return;

        const trailing = emitter.document.literal_span(emitter.literals.comma);

        try emitter.document.push(.{ .if_broken = trailing });
    }

    fn separates_closing(emitter: *const Emitter, position: u32, opening: Kind) bool {
        assert(position < emitter.raw.len);
        assert(is_open(opening));

        const count: u32 = @intCast(emitter.tokens.len);
        var scan = position + 1;

        while (scan < count) : (scan += 1) {
            const kind = emitter.raw[scan];
            const skipped = kind == .comment or is_layout(kind);
            if (skipped) continue;
            return is_close(kind) and opened_by(kind) == opening;
        }

        return true;
    }

    fn suite(emitter: *Emitter, position: u32) error{Overflow}!bool {
        assert(position < emitter.raw.len);
        assert(emitter.raw[position] == .colon);

        if (!opens_suite(emitter.line_first)) return false;

        const definition = emitter.opens_definition(emitter.line_first_at.?);
        const collapses = definition or emitter.stub;
        const gathers = collapses and emitter.stubbed_at(position) != null;
        const ellipsis = collapses and (gathers or emitter.stubs(position));
        const functional = emitter.line_first != .class_keyword and emitter.line_first != .at;

        emitter.stubbed = definition and ellipsis;
        emitter.stubbed_function = emitter.stubbed and functional;

        if (emitter.stub) stub_file.ellipsis(emitter, emitter.stubbed);

        if (gathers) {
            try emitter.stubbing(position);

            return true;
        }

        const inlining = !ellipsis and emitter.inlines(position);

        if (inlining) {
            try emitter.inlined(position);

            return true;
        }

        return false;
    }

    fn stubbing(emitter: *Emitter, position: u32) error{Overflow}!void {
        assert(position < emitter.raw.len);
        assert(emitter.raw[position] == .colon);

        const ellipsis = emitter.stubbed_at(position).?;
        const end = emitter.stubbed_end(ellipsis).?;
        const riding = emitter.rider(ellipsis);
        const spacing = emitter.spaced(.colon);

        assert(end > ellipsis);

        try emitter.text(position, spacing);
        try emitter.document.push(.space);
        try emitter.text(ellipsis, false);

        if (riding) |comment_at| try emitter.rides(comment_at);

        emitter.pending_break = true;
        emitter.until = end + 1;
    }

    pub fn stubbed_at(emitter: *const Emitter, position: u32) ?u32 {
        assert(position < emitter.raw.len);
        assert(emitter.raw.len == emitter.tokens.len);

        const count: u32 = @intCast(emitter.tokens.len);
        var indent = false;
        var scan = position + 1;

        while (scan < count) : (scan += 1) {
            const kind = emitter.raw[scan];
            if (kind == .newline) continue;

            if (kind == .indent) {
                if (indent) return null;

                indent = true;

                continue;
            }

            const stub = kind == .ellipsis and indent and emitter.stubbed_end(scan) != null;

            if (stub) {
                assert(scan <= emitter.tokens.len);

                return scan;
            }

            return null;
        }

        return null;
    }

    fn stubbed_end(emitter: *const Emitter, position: u32) ?u32 {
        assert(position < emitter.raw.len);
        assert(emitter.raw[position] == .ellipsis);

        const count: u32 = @intCast(emitter.tokens.len);
        var trailed = false;
        var scan = position + 1;

        while (scan < count) : (scan += 1) {
            const kind = emitter.raw[scan];
            const passed = kind == .newline or kind == .semicolon;
            const trailing = kind == .comment and !trailed and !emitter.heads_line(scan);

            if (passed) continue;

            if (trailing) {
                trailed = true;

                continue;
            }

            if (kind == .dedent) {
                assert(scan <= emitter.tokens.len);

                return scan;
            }

            return null;
        }

        return null;
    }

    pub fn stubs(emitter: *const Emitter, position: u32) bool {
        assert(position < emitter.raw.len);
        assert(emitter.raw.len == emitter.tokens.len);

        const count: u32 = @intCast(emitter.tokens.len);
        var found = false;
        var scan = position + 1;

        while (scan < count) : (scan += 1) {
            const kind = emitter.raw[scan];
            if (is_layout(kind)) return found and kind == .newline;

            const passed = kind == .comment or kind == .semicolon;
            const trailing = passed and found;
            if (trailing) continue;
            if (kind != .ellipsis) return false;
            if (found) return false;

            found = true;
        }

        return found;
    }

    fn inlines(emitter: *const Emitter, position: u32) bool {
        assert(position < emitter.raw.len);
        assert(emitter.raw.len == emitter.tokens.len);

        const count: u32 = @intCast(emitter.tokens.len);
        var scan = position + 1;

        while (scan < count) : (scan += 1) {
            const kind = emitter.raw[scan];
            if (kind == .comment) return false;
            if (ends_line(kind)) return false;
            if (!is_layout(kind)) return true;
        }

        return false;
    }

    fn outlines(emitter: *Emitter) error{Overflow}!void {
        assert(emitter.@"inline" <= emitter.indent);
        assert(emitter.indent <= bracket_depth_max);

        while (emitter.@"inline" > 0) {
            emitter.@"inline" -= 1;
            emitter.indent -= 1;
            emitter.closed = emitter.blocks[emitter.indent];
            emitter.after = emitter.after or emitter.closed;

            try emitter.document.push(.dedent);
        }
    }

    fn splits_held(emitter: *const Emitter) Splits {
        assert(emitter.depth <= bracket_depth_max);

        if (emitter.depth > 0) return emitter.frames[emitter.depth - 1].splits;
        if (emitter.wrap != null) return emitter.wrapper.splits;
        return .new();
    }

    fn parting(emitter: *Emitter, kind: Kind) u8 {
        assert(kind.is_token());
        assert(emitter.depth <= bracket_depth_max);

        const previous = emitter.previous;

        if (emitter.depth == 0) {
            if (emitter.wrap != null) return emitter.wrapper.splits.step(kind, previous);

            var fresh: Splits = .new();
            return fresh.step(kind, previous);
        }

        const returned = emitter.frames[emitter.depth - 1].splits.step(kind, previous);

        assert(returned < std.math.maxInt(u8));

        return returned;
    }

    fn valued(emitter: *const Emitter, position: u32) ?u32 {
        assert(position <= emitter.raw.len);
        assert(emitter.raw.len == emitter.tokens.len);

        const count: u32 = @intCast(emitter.tokens.len);
        var depth: u32 = 0;
        var previous: ?Kind = null;
        var prior: ?u32 = null;
        var splits: Splits = .new();
        var scan = position;

        while (scan < count) : (scan += 1) {
            const kind = emitter.raw[scan];
            const skipped = is_layout(kind) or kind == .comment;
            if (skipped) continue;

            if (is_close(kind)) {
                if (depth == 0) return null;

                depth -= 1;
            }

            if (depth == 0) {
                if (kind == .comma) return null;

                const bracketed = is_open(kind) and emitter.holds(scan + 1);
                if (bracketed) return scan;
                if (splits.step(kind, previous) > 0) return prior;
            }

            depth += @intFromBool(is_open(kind));
            previous = kind;
            prior = scan;
        }

        return null;
    }

    fn holds(emitter: *const Emitter, position: u32) bool {
        assert(position <= emitter.raw.len);
        assert(emitter.raw.len == emitter.tokens.len);

        const count: u32 = @intCast(emitter.tokens.len);
        var scan = position;

        while (scan < count) : (scan += 1) {
            const kind = emitter.raw[scan];
            const content = !is_layout(kind) and kind != .comment;
            if (content) return !is_close(kind);
        }

        return false;
    }

    fn entry_at(emitter: *const Emitter, position: u32) ?u32 {
        assert(position < emitter.raw.len);
        assert(emitter.raw.len == emitter.tokens.len);

        var depth: u32 = 0;
        var scan = position;

        while (scan > 0) {
            scan -= 1;

            const kind = emitter.raw[scan];

            if (is_open(kind)) {
                if (depth == 0) {
                    assert(scan + 1 <= emitter.tokens.len);

                    return scan + 1;
                }

                depth -= 1;

                continue;
            }

            if (is_close(kind)) {
                depth += 1;

                continue;
            }

            const separated = depth == 0 and kind == .comma;

            if (separated) {
                assert(scan + 1 <= emitter.tokens.len);

                return scan + 1;
            }
        }

        return null;
    }

    pub fn measured(emitter: *const Emitter, from: u32, to: u32) u32 {
        assert(emitter.raw.len == emitter.tokens.len);
        if (from <= to) assert(to < emitter.raw.len);

        var held: ?Kind = null;
        var scan = from;
        var width: u32 = 0;

        while (scan <= to) {
            const kind = emitter.raw[scan];
            const piece = emitter.tokens[scan];
            const skipped = emitter.drops(scan, null) or is_layout(kind) or piece.length == 0;

            if (skipped) {
                scan += 1;

                continue;
            }

            const blank = if (held) |prior| blank_between(emitter, prior, scan) else false;

            if (kind == .f_string_start) {
                const end = emitter.format_end(scan);

                width += emitter.tokens[end].end() - piece.offset + @intFromBool(blank);
                held = .f_string_end;
                scan = end + 1;

                continue;
            }

            width += columns(emitter.source, piece.offset, piece.end()) + @intFromBool(blank);
            held = kind;
            scan += 1;
        }

        return width;
    }

    fn measured_line(emitter: *const Emitter, from: u32, end: u32) u32 {
        assert(from < emitter.tokens.len);
        assert(end <= emitter.tokens.len);

        const last = @min(end, @as(u32, @intCast(emitter.tokens.len)) - 1);
        return emitter.measured(from, last);
    }

    fn entered(emitter: *const Emitter, position: u32) bool {
        assert(position < emitter.raw.len);
        assert(emitter.depth <= bracket_depth_max);

        const head = emitter.valued(position + 1) orelse return false;
        const start = emitter.entry_at(position) orelse return false;
        const column = (emitter.indent + emitter.depth) * emitter.indent_width;

        assert(start <= position);

        return column + emitter.measured(start, head) <= emitter.line_width;
    }

    fn keyed(emitter: *const Emitter, position: u32) bool {
        assert(position < emitter.raw.len);
        assert(emitter.depth <= bracket_depth_max);

        if (emitter.depth == 0) return false;
        if (emitter.frame().kind != .brace_open) return false;

        const count: u32 = @intCast(emitter.tokens.len);
        var depth: u32 = 0;
        var scan = position;

        while (scan < count) : (scan += 1) {
            const kind = emitter.raw[scan];

            if (is_close(kind)) {
                if (depth == 0) return false;

                depth -= 1;

                continue;
            }

            if (is_open(kind)) {
                depth += 1;

                continue;
            }

            if (depth > 0) continue;
            if (kind == .comma) return false;
            if (kind == .newline) return false;
            if (kind == .colon) return emitter.entered(scan);
        }

        return false;
    }

    pub fn rides(emitter: *Emitter, position: u32) error{Overflow}!void {
        assert(position < emitter.raw.len);
        assert(emitter.raw[position] == .comment);

        const gap_span = emitter.document.literal_span(emitter.literals.gap);
        const lexeme = emitter.tokens[position];
        const marked = pragmatic(emitter.source[lexeme.offset..lexeme.end()]);

        emitter.until = position + 1;

        if (marked) try emitter.document.push(.pragma);

        try emitter.document.push(.{ .text = .{ .source = .literal, .span = gap_span } });
        try emitter.text(position, false);
    }

    fn comment_normalized(emitter: *Emitter, span: Span) ?Span {
        assert(span.end() <= emitter.source.len);

        const bytes = span.text(emitter.source);
        if (bytes.len < 2) return null;

        switch (bytes[1]) {
            ' ', '!', '#', '\'', ':' => return null,
            else => {},
        }

        const offset = emitter.arena.count();

        pushed_parts(emitter.arena, &.{ "# ", bytes[1..] }) catch |err| switch (err) {
            error.Overflow => {
                emitter.arena.truncate(offset);

                return null;
            },
        };

        assert(emitter.arena.count() == offset + bytes.len + 1);

        return .{ .offset = offset, .length = emitter.arena.count() - offset };
    }

    fn relit(emitter: *Emitter, span: Span) ?Span {
        assert(span.end() <= emitter.source.len);

        const bytes = span.text(emitter.source);
        const offset = emitter.arena.count();
        const preference = interpolated.preference(emitter, bytes);

        relettered(emitter.arena, bytes, preference) catch |err| switch (err) {
            error.Overflow => {
                emitter.arena.truncate(offset);

                return null;
            },
        };

        assert(emitter.arena.count() >= offset);

        return emitter.written(offset, bytes);
    }

    pub fn written(emitter: *Emitter, offset: u32, bytes: []const u8) ?Span {
        assert(offset <= emitter.arena.count());
        assert(bytes.len <= std.math.maxInt(u32));

        const held: Span = .{ .offset = offset, .length = emitter.arena.count() - offset };

        if (std.mem.eql(u8, held.text(emitter.arena.const_slice()), bytes)) {
            emitter.arena.truncate(offset);

            return null;
        }

        if (held.length == 0) assert(bytes.len > 0);

        return held;
    }

    fn renumber(emitter: *Emitter, span: Span) ?Span {
        assert(span.end() <= emitter.source.len);

        const bytes = span.text(emitter.source);
        const offset = emitter.arena.count();

        numbered(emitter.arena, bytes) catch |err| switch (err) {
            error.Overflow => {
                emitter.arena.truncate(offset);

                return null;
            },
        };

        assert(emitter.arena.count() >= offset);

        return emitter.written(offset, bytes);
    }

    fn requote(emitter: *Emitter, span: Span, preference: QuotePreference) ?Span {
        assert(span.end() <= emitter.source.len);

        const pieces = requoted(span.text(emitter.source), preference) orelse return null;
        const offset = emitter.arena.count();
        const sequence = [_][]const u8{ pieces.prefix, pieces.quote, pieces.body, pieces.quote };

        pushed_parts(emitter.arena, &sequence) catch |err| switch (err) {
            error.Overflow => {
                emitter.arena.truncate(offset);

                return null;
            },
        };

        assert(emitter.arena.count() - offset == span.length);

        return .{ .offset = offset, .length = emitter.arena.count() - offset };
    }

    fn step(emitter: *Emitter, position: u32, kind: Kind, wrote: *bool) error{Overflow}!void {
        assert(position < emitter.tokens.len);
        assert(emitter.raw[position] == kind);

        if (kind == .dedent) {
            if (emitter.lowered > 0) {
                emitter.lowered -= 1;

                return;
            }

            emitter.indent -= 1;
            emitter.closed = emitter.blocks[emitter.indent];
            emitter.after = emitter.after or emitter.closed;

            return emitter.document.push(.dedent);
        }

        if (kind == .indent) return emitter.indented(position, emitter.column_after(position));

        if (kind == .newline) {
            if (emitter.wrap == position) try emitter.unwrap();

            emitter.pending_break = wrote.*;

            return emitter.outlines();
        }

        wrote.* = true;

        if (emitter.wrap == position) try emitter.unwrap();

        return emitter.token(position, kind);
    }

    fn wide(emitter: *Emitter, position: u32, kind: Kind) error{Overflow}!bool {
        assert(position < emitter.tokens.len);
        assert(emitter.raw[position] == kind);

        if (emitter.region_end(position)) |region| {
            try emitter.verbatim(position, region);

            return true;
        }

        if (emitter.formatted.active()) {
            if (try interpolated.piece(emitter, position, kind)) return true;
        }

        if (kind != .f_string_start) return false;

        try emitter.fstring(position);

        return true;
    }

    fn elides(emitter: *Emitter, position: u32, kind: Kind) bool {
        assert(position < emitter.tokens.len);
        assert(emitter.elisions <= bracket_depth_max);
        assert(kind.is_token());

        const closes = kind == .paren_close and emitter.elisions > 0 and
            emitter.elided[emitter.elisions - 1] == position;

        if (closes) {
            emitter.elisions -= 1;

            return true;
        }

        if (kind != .paren_open) return false;
        if (emitter.elisions == bracket_depth_max) return false;

        var close_at = elided.doubled(emitter, position);

        if (close_at == null) {
            const bodied = emitter.previous == .colon and emitter.lambdas(emitter.at_previous.?);

            if (emitter.depth > 0) {
                if (!bodied) return false;
            }

            close_at = elided.elidable(emitter, position);
        }

        const held = close_at orelse return false;

        emitter.elided[emitter.elisions] = held;
        emitter.elisions += 1;

        assert(held > position);

        emitter.elided_line.record(position, held);

        return true;
    }

    pub fn drops(emitter: *const Emitter, position: u32, dropped: ?u32) bool {
        assert(position < emitter.tokens.len);

        if (dropped == position) return true;
        return emitter.elided_line.holds(position);
    }

    pub fn omits(emitter: *const Emitter, open_at: u32, ceiling: u32, dropped: ?u32) bool {
        assert(open_at < ceiling);
        assert(ceiling <= emitter.tokens.len);
        if (dropped) |held| assert(held < emitter.tokens.len);

        return emitter.omits_fitted(open_at, ceiling, dropped, true);
    }

    fn omits_fitted(
        emitter: *const Emitter,
        open_at: u32,
        ceiling: u32,
        dropped: ?u32,
        fitting: bool,
    ) bool {
        assert(open_at < ceiling);
        assert(ceiling <= emitter.tokens.len);
        if (dropped) |held| assert(held < emitter.tokens.len);

        const listed_whole = emitter.listed_line(open_at + 1, ceiling);
        const close_at = if (listed_whole) ceiling else emitter.named_end(open_at, ceiling);
        const split = emitter.omits_split(open_at, close_at);

        if (split.count > 1) {
            if (split.found != priority_comparator) return false;
            if (!spanned.spans(emitter, open_at, close_at)) return false;
            return spanned.spans_head(emitter, open_at + 1, close_at, split.found);
        }

        if (spanned.omits(emitter, open_at, close_at, split.found)) return true;

        const dotted = split.found == 0 or split.found == priority_dot;

        if (!dotted) {
            if (spanned.spans(emitter, open_at, close_at)) {
                if (emitter.omits_whole(open_at, close_at)) return true;
                return spanned.spans_head(emitter, open_at + 1, close_at, split.found);
            }
        }

        if (emitter.omits_whole(open_at, close_at)) return true;

        if (emitter.next_token(open_at, close_at)) |first| {
            if (onset.parenthesized_first(emitter, first, close_at)) {
                return emitter.omits_head(first, close_at);
            }
        }

        if (dotted) {
            if (emitter.primaried(open_at, close_at)) {
                const named = close_at != ceiling;
                return emitter.omits_primary(open_at, close_at, dropped, fitting and !named);
            }
        }

        if (split.found == priority_comma) {
            if (emitter.parted_at(open_at, close_at, priority_comma)) |comma_at| {
                if (emitter.omits_tail(open_at, comma_at, dropped)) return true;
            }
        }

        return emitter.omits_tail(open_at, close_at, dropped);
    }

    fn omits_split(emitter: *const Emitter, open_at: u32, close_at: u32) OmitsSplit {
        assert(open_at < close_at);
        assert(close_at <= emitter.tokens.len);

        return emitter.splits_from(open_at + 1, close_at);
    }

    pub fn splits_from(emitter: *const Emitter, from: u32, close_at: u32) OmitsSplit {
        assert(from <= close_at);
        assert(close_at <= emitter.tokens.len);

        var count: u32 = 0;
        var depth: u32 = 0;
        var found: u8 = 0;
        var previous: ?Kind = null;
        var splits: Splits = .new();
        var scan = from;

        while (scan < close_at) : (scan += 1) {
            const kind = emitter.raw[scan];
            if (is_layout(kind)) continue;

            if (depth == 0) {
                const priority = splits.step(kind, previous);

                if (priority > found) {
                    found = priority;
                    count = 0;
                }

                const counted = priority > 0 and priority == found;

                if (counted) count += 1;
            }

            if (is_open(kind)) depth += 1;
            if (is_close(kind)) depth -|= 1;

            previous = kind;
        }

        assert(count <= close_at - from);
        assert(found <= priority_comprehension);

        return .{ .count = count, .found = found };
    }

    fn omits_whole(emitter: *const Emitter, open_at: u32, close_at: u32) bool {
        assert(open_at < close_at);
        assert(close_at <= emitter.tokens.len);

        const last = emitter.prior_token(close_at, open_at) orelse return false;
        const closed = is_close(emitter.raw[last]);
        const virtual = if (closed) null else emitter.powered_last(open_at, last);

        if (!closed) {
            if (virtual == null) return false;
        }

        const opening = virtual orelse (emitter.opened_at(last) orelse return false);
        var scan = open_at;

        for (open_at..close_at) |_| {
            const held = emitter.next_token(scan, close_at) orelse return false;

            assert(held > scan);

            if (held == opening) return virtual == null or is_unary(emitter.raw[held]);
            if (!is_unary(emitter.raw[held])) return false;

            scan = held;
        }

        return false;
    }

    fn omits_head(emitter: *const Emitter, first: u32, close_at: u32) bool {
        assert(first < close_at);
        assert(is_open(emitter.raw[first]));

        const closing = emitter.closed_at(first) orelse return true;
        const last = emitter.prior_token(close_at, first) orelse return true;
        if (closing >= last) return true;

        const flat = emitter.indent * emitter.indent_width;
        var scan = closing + 1;

        while (scan < last) : (scan += 1) {
            const kind = emitter.raw[scan];

            if (kind == .f_string_start) {
                scan = emitter.format_end(scan);

                continue;
            }

            if (!is_open(kind)) continue;
            if (!emitter.filled(scan, close_at)) continue;
            return flat + emitter.measured(closing, scan) <= emitter.line_width;
        }

        const tail = close_at < emitter.tokens.len and emitter.raw[close_at] == .colon;
        return flat + emitter.measured(closing, last) + @intFromBool(tail) <= emitter.line_width;
    }

    fn powered_last(emitter: *const Emitter, open_at: u32, last: u32) ?u32 {
        assert(open_at < last);
        assert(last < emitter.tokens.len);

        var depth: u32 = 0;
        var previous: ?Kind = emitter.raw[open_at];
        var scan = open_at + 1;

        while (scan < last) : (scan += 1) {
            const kind = emitter.raw[scan];
            if (is_layout(kind)) continue;
            if (kind == .comment) continue;

            if (depth == 0) {
                if (is_unary(kind)) {
                    if (power.powered(emitter, scan, previous) == last) {
                        assert(scan <= emitter.tokens.len);

                        return scan;
                    }
                }
            }

            if (is_open(kind)) depth += 1;
            if (is_close(kind)) depth -|= 1;

            previous = kind;
        }

        return null;
    }

    fn omits_primary(
        emitter: *const Emitter,
        open_at: u32,
        close_at: u32,
        dropped: ?u32,
        fitting: bool,
    ) bool {
        assert(open_at < close_at);
        assert(close_at <= emitter.tokens.len);
        if (dropped) |held| assert(held < emitter.tokens.len);

        const parenthesized = emitter.messages(open_at) or onset.guards(emitter, open_at);

        if (!parenthesized) {
            if (!emitter.wrap_opens(open_at, dropped)) return true;
        }

        if (emitter.omits_target(open_at, close_at, dropped)) return true;

        const opening = emitter.primary_bracket(open_at, close_at) orelse {
            if (parenthesized) return false;
            if (emitter.raw[open_at] == .yield_keyword) return true;
            if (onset.owned_target(emitter, open_at)) return false;
            return !emitter.wrap_holds(open_at, close_at);
        };

        if (emitter.omits_width(open_at, opening, dropped, 0)) return true;
        if (!fitting) return false;
        if (emitter.messages(open_at)) return false;
        if (onset.guards(emitter, open_at)) return false;
        return !emitter.holds_from(open_at + 1, opening + 1);
    }

    pub fn messages(emitter: *const Emitter, open_at: u32) bool {
        assert(open_at < emitter.tokens.len);
        assert(emitter.depth <= bracket_depth_max);

        if (emitter.line_first != .assert_keyword) return false;
        if (emitter.depth > 0) return false;

        const kind = emitter.raw[open_at];
        if (kind == .comma) return true;
        if (kind != .paren_open) return false;

        const floor = emitter.line_first_at orelse return false;
        const prior = emitter.prior_token(open_at, floor) orelse return false;

        return emitter.raw[prior] == .comma;
    }

    fn omits_target(emitter: *const Emitter, open_at: u32, close_at: u32, dropped: ?u32) bool {
        assert(open_at < close_at);
        if (dropped) |held| assert(held < emitter.tokens.len);

        var equal = open_at;

        if (emitter.raw[open_at] == .paren_open) {
            equal = emitter.prior_token(open_at, emitter.line_first_at.?) orelse return false;
        }

        const operator = emitter.raw[equal];

        if (operator != .equal) {
            if (!is_augmented(operator)) return false;
        }

        if (onset.left_first(emitter, equal, close_at)) {
            const last = emitter.prior_token(equal, emitter.line_first_at.?) orelse return false;
            const kind = emitter.raw[last];

            if (kind != .bracket_close) {
                if (kind != .paren_close) return false;
            }

            return emitter.target_bracket(equal, dropped, false);
        }

        if (operator == .equal) {
            if (onset.annotates(emitter, equal)) return false;
        }

        const chained = emitter.target_end(equal + 1) != null;

        if (operator == .equal) {
            if (emitter.assigned(equal)) {
                if (!chained) return false;
            }
        }

        return emitter.target_bracket(equal, dropped, !chained);
    }

    fn target_bracket(emitter: *const Emitter, end: u32, dropped: ?u32, trailed: bool) bool {
        assert(end <= emitter.tokens.len);
        if (dropped) |held| assert(held < emitter.tokens.len);

        const floor = emitter.line_first_at orelse return false;
        var scan = end;

        while (scan > floor) {
            scan -= 1;

            if (!is_close(emitter.raw[scan])) continue;

            const opening = emitter.opened_at(scan) orelse return false;

            if (!emitter.filled(opening, scan)) {
                scan = opening;

                continue;
            }

            if (trailed) {
                if (emitter.next_token(scan, end) == null) return false;
            }

            return emitter.head_columns(opening, dropped) <= emitter.line_width;
        }

        return false;
    }

    fn assigned(emitter: *const Emitter, position: u32) bool {
        assert(position < emitter.tokens.len);
        assert(emitter.raw[position] == .equal);

        const floor = emitter.line_first_at orelse return false;
        var depth: u32 = 0;
        var scan = position;

        while (scan > floor) {
            scan -= 1;

            const kind = emitter.raw[scan];

            if (is_close(kind)) depth += 1;
            if (is_open(kind)) depth -|= 1;

            const found = depth == 0 and kind == .equal;
            if (found) return true;
        }

        return false;
    }

    pub fn format_end(emitter: *const Emitter, position: u32) u32 {
        assert(position < emitter.tokens.len);
        assert(emitter.tokens.len == emitter.raw.len);

        const count: u32 = @intCast(emitter.tokens.len);
        var depth: u32 = 0;
        var scan = position;

        while (scan < count) : (scan += 1) {
            const kind = emitter.raw[scan];

            if (kind == .f_string_start) depth += 1;

            if (kind == .f_string_end) {
                depth -= 1;

                if (depth == 0) return scan;
            }
        }

        return position;
    }

    fn wrap_opens(emitter: *const Emitter, open_at: u32, dropped: ?u32) bool {
        assert(open_at < emitter.tokens.len);
        assert(emitter.indent <= bracket_depth_max);
        if (dropped) |held| assert(held < emitter.tokens.len);

        return emitter.head_columns(open_at, dropped) + 2 <= emitter.line_width;
    }

    fn wrap_holds(emitter: *const Emitter, open_at: u32, close_at: u32) bool {
        assert(open_at < close_at);
        assert(close_at <= emitter.tokens.len);

        return emitter.holds_from(open_at + 1, close_at);
    }

    pub fn holds_from(emitter: *const Emitter, from: u32, close_at: u32) bool {
        assert(from <= close_at);
        assert(close_at <= emitter.tokens.len);

        var held: ?Kind = null;
        var scan = from;
        var width = (emitter.indent + 1) * emitter.indent_width;

        while (scan < close_at) {
            const kind = emitter.raw[scan];
            const lexeme = emitter.tokens[scan];
            const skipped = emitter.drops(scan, null) or is_layout(kind) or lexeme.length == 0;

            if (skipped) {
                scan += 1;

                continue;
            }

            const blank: u32 = if (held) |prior|
                @intFromBool(blank_between(emitter, prior, scan))
            else
                0;

            if (kind == .f_string_start) {
                const end = emitter.format_end(scan);

                width += emitter.tokens[end].end() - lexeme.offset + blank;
                held = .f_string_end;
                scan = end + 1;

                continue;
            }

            const trailing = kind == .comment and held != null;
            const spacing: u32 = if (trailing) gap.len else blank;
            const marked = trailing and pragmatic(lexeme.text(emitter.source));

            if (!marked) width += columns(emitter.source, lexeme.offset, lexeme.end()) + spacing;

            held = kind;
            scan += 1;
        }

        return width <= emitter.line_width;
    }

    fn element_start(emitter: *const Emitter, ceiling: u32) ?u32 {
        assert(ceiling < emitter.tokens.len);
        assert(emitter.depth <= bracket_depth_max);

        if (emitter.depth == 0) return emitter.line_first_at;
        if (emitter.line_first_at == null) return null;
        return elided.element_first(emitter, ceiling);
    }

    fn head_columns(emitter: *const Emitter, ceiling: u32, dropped: ?u32) u32 {
        assert(ceiling < emitter.tokens.len);
        assert(emitter.indent <= bracket_depth_max);
        if (dropped) |held| assert(held < emitter.tokens.len);

        const flat = emitter.indent * emitter.indent_width;

        assert(flat < std.math.maxInt(u32));

        const start = emitter.element_start(ceiling) orelse return flat;
        const nested = (emitter.indent + emitter.depth) * emitter.indent_width;
        var held: ?Kind = null;
        var scan = start;
        var width = if (emitter.line_first_at == start) flat else nested;

        while (scan <= ceiling) {
            const kind = emitter.raw[scan];
            const lexeme = emitter.tokens[scan];
            const skipped = emitter.drops(scan, dropped) or is_layout(kind) or lexeme.length == 0;

            if (skipped) {
                scan += 1;

                continue;
            }

            const blank: u32 = if (held) |prior|
                @intFromBool(blank_between(emitter, prior, scan))
            else
                0;

            if (kind == .f_string_start) {
                const end = emitter.format_end(scan);

                width += emitter.tokens[end].end() - lexeme.offset + blank;
                held = .f_string_end;
                scan = end + 1;

                continue;
            }

            width += columns(emitter.source, lexeme.offset, lexeme.end()) + blank;
            held = kind;
            scan += 1;
        }

        return width;
    }

    fn named_end(emitter: *const Emitter, open_at: u32, close_at: u32) u32 {
        assert(open_at < close_at);
        assert(close_at <= emitter.tokens.len);

        const last = emitter.prior_token(close_at, open_at) orelse return close_at;
        if (emitter.raw[last] != .identifier) return close_at;

        const word = emitter.prior_token(last, open_at) orelse return close_at;
        if (emitter.raw[word] == .as_keyword) return word;
        return close_at;
    }

    fn parted_at(emitter: *const Emitter, open_at: u32, close_at: u32, priority: u8) ?u32 {
        assert(open_at < close_at);
        assert(priority > 0);

        var depth: u32 = 0;
        var previous: ?Kind = null;
        var splits: Splits = .new();
        var scan = open_at + 1;

        while (scan < close_at) : (scan += 1) {
            const kind = emitter.raw[scan];
            if (is_layout(kind)) continue;

            if (depth == 0) {
                if (splits.step(kind, previous) == priority) {
                    assert(scan <= emitter.tokens.len);

                    return scan;
                }
            }

            if (is_open(kind)) depth += 1;
            if (is_close(kind)) depth -|= 1;

            previous = kind;
        }

        return null;
    }

    fn primaried(emitter: *const Emitter, open_at: u32, close_at: u32) bool {
        assert(open_at < close_at);
        assert(close_at <= emitter.tokens.len);

        var depth: u32 = 0;
        var format: u32 = 0;
        var held = false;
        var scan = open_at + 1;

        while (scan < close_at) : (scan += 1) {
            const kind = emitter.raw[scan];

            if (kind == .f_string_start) format += 1;

            if (format > 0) {
                format -= @intFromBool(kind == .f_string_end);

                continue;
            }

            if (is_open(kind)) depth += 1;
            if (is_close(kind)) depth -|= 1;

            const operand = depth == 0 and !is_layout(kind);
            if (!operand) continue;

            const prefixed = !held and prefixes(kind);
            if (prefixed) continue;

            const primary = kind == .dot or ends_operand(kind);
            if (!primary) return false;

            held = true;
        }

        return true;
    }

    pub fn filled(emitter: *const Emitter, position: u32, ceiling: u32) bool {
        assert(position < emitter.tokens.len);
        assert(ceiling <= emitter.tokens.len);

        const inner = emitter.next_token(position, ceiling) orelse return false;
        return !is_close(emitter.raw[inner]);
    }

    fn primary_bracket(emitter: *const Emitter, open_at: u32, close_at: u32) ?u32 {
        assert(open_at < close_at);
        assert(close_at <= emitter.tokens.len);

        var format: u32 = 0;
        var scan = open_at + 1;

        while (scan < close_at) : (scan += 1) {
            const kind = emitter.raw[scan];

            if (kind == .f_string_start) format += 1;

            if (format > 0) {
                format -= @intFromBool(kind == .f_string_end);

                continue;
            }

            if (is_open(kind)) {
                if (emitter.filled(scan, close_at)) {
                    assert(scan <= emitter.tokens.len);

                    return scan;
                }

                scan = emitter.next_token(scan, close_at) orelse return null;
            }
        }

        return null;
    }

    pub fn next_token(emitter: *const Emitter, position: u32, ceiling: u32) ?u32 {
        assert(position < emitter.tokens.len);
        assert(ceiling <= emitter.tokens.len);

        var scan = position + 1;

        while (scan < ceiling) : (scan += 1) {
            const significant = !is_layout(emitter.raw[scan]) and emitter.tokens[scan].length > 0;

            if (significant) {
                assert(scan <= emitter.tokens.len);

                return scan;
            }
        }

        return null;
    }

    pub fn omits_tail(emitter: *const Emitter, open_at: u32, close_at: u32, dropped: ?u32) bool {
        assert(open_at < close_at);
        assert(close_at <= emitter.tokens.len);
        if (dropped) |held| assert(held < emitter.tokens.len);

        const last = emitter.prior_token(close_at, open_at) orelse return false;
        const kind = emitter.raw[last];

        if (!is_close(kind)) {
            const unary = emitter.powered_last(open_at, last) orelse return false;
            const negated = emitter.raw[unary] == .not_keyword;
            const extra: u32 = if (negated) paren_open.len else paren_head.len;

            return emitter.omits_width(open_at, unary, dropped, extra);
        }

        const opening = emitter.opened_at(last) orelse return false;
        if (emitter.prior_token(last, open_at) == opening) return false;

        const called = if (emitter.prior_token(opening, open_at)) |held|
            ends_operand(emitter.raw[held])
        else
            false;

        if (kind == .bracket_close) {
            if (called) return false;
        }

        if (kind == .paren_close) {
            if (!called) {
                if (power.subscript_parenthesized(emitter, opening, last)) return false;
            }
        }

        return emitter.omits_width(open_at, opening, dropped, 0);
    }

    pub fn omits_width(
        emitter: *const Emitter,
        open_at: u32,
        opening: u32,
        dropped: ?u32,
        extra: u32,
    ) bool {
        assert(open_at < emitter.tokens.len);
        assert(opening < emitter.tokens.len);
        if (dropped) |held| assert(held < emitter.tokens.len);
        assert(extra < std.math.maxInt(u32));

        const start = emitter.element_start(open_at) orelse return false;
        const flat = emitter.indent * emitter.indent_width;
        const nested = (emitter.indent + emitter.depth) * emitter.indent_width;
        var held: ?Kind = null;
        var scan = start;
        var width = if (emitter.line_first_at == start) flat else nested;

        while (scan <= opening) {
            const kind = emitter.raw[scan];
            const lexeme = emitter.tokens[scan];
            const skipped = emitter.drops(scan, dropped) or is_layout(kind) or lexeme.length == 0;

            if (skipped) {
                scan += 1;

                continue;
            }

            const reset = scan < open_at and is_close(kind) and held == .comma;

            if (reset) {
                width = flat;
                held = null;
            }

            const blank: u32 = if (held) |prior|
                @intFromBool(blank_between(emitter, prior, scan))
            else
                0;

            if (kind == .f_string_start) {
                const end = emitter.format_end(scan);
                const last = emitter.tokens[end].end();

                width = emitter.spanned_from(lexeme.offset, last) orelse
                    width + last - lexeme.offset + blank;

                held = .f_string_end;
                scan = end + 1;

                continue;
            }

            width = emitter.spanned_from(lexeme.offset, lexeme.end()) orelse
                width + columns(emitter.source, lexeme.offset, lexeme.end()) + blank;

            if (scan == opening) {
                if (onset.shortcuts(emitter, open_at, opening, dropped)) return true;
                return width + extra + onset.rider_columns(emitter, opening) <= emitter.line_width;
            }

            held = kind;
            scan += 1;
        }

        return false;
    }

    fn spanned_from(emitter: *const Emitter, offset: u32, end: u32) ?u32 {
        assert(offset <= end);
        assert(end <= emitter.source.len);

        const at = std.mem.findScalarLast(u8, emitter.source[offset..end], '\n') orelse {
            return null;
        };

        const from = offset + @as(u32, @intCast(at)) + 1;
        return columns(emitter.source, from, end);
    }

    pub fn prior_token(emitter: *const Emitter, position: u32, floor: u32) ?u32 {
        assert(position <= emitter.tokens.len);
        assert(floor < std.math.maxInt(u32));

        var scan = position;

        while (scan > floor + 1) {
            scan -= 1;

            const significant = !is_layout(emitter.raw[scan]) and emitter.tokens[scan].length > 0;
            if (significant) return scan;
        }

        return null;
    }

    pub fn opened_at(emitter: *const Emitter, position: u32) ?u32 {
        assert(position < emitter.tokens.len);
        assert(is_close(emitter.raw[position]));

        var depth: u32 = 0;
        var scan = position + 1;

        while (scan > 0) {
            scan -= 1;

            const kind = emitter.raw[scan];

            if (is_close(kind)) depth += 1;

            if (is_open(kind)) {
                depth -= 1;

                if (depth == 0) {
                    assert(scan <= emitter.tokens.len);

                    return scan;
                }
            }
        }

        return null;
    }

    pub fn tails_line(emitter: *const Emitter, position: u32) bool {
        assert(position < emitter.tokens.len);
        assert(emitter.tokens.len == emitter.raw.len);

        const count: u32 = @intCast(emitter.tokens.len);
        var scan = position + 1;

        while (scan < count) : (scan += 1) {
            const kind = emitter.raw[scan];
            if (ends_line(kind)) return true;

            const trailing = is_layout(kind) or is_close(kind);
            if (!trailing) return false;
        }

        return true;
    }

    pub fn elided_body(
        emitter: *const Emitter,
        position: u32,
        close_at: u32,
        targets: Targets,
        headed: bool,
    ) bool {
        assert(position < close_at);
        assert(close_at < emitter.tokens.len);

        var depth: u32 = 0;
        var held = false;
        var prior: ?Kind = null;
        var scan = position + 1;

        while (scan < close_at) : (scan += 1) {
            const kind = emitter.raw[scan];
            const bracket = is_open(kind) or is_close(kind);

            if (is_open(kind)) depth += 1;
            if (is_close(kind)) depth -= 1;

            const nested = kind == .comment and depth > 0;

            if (!bracket) {
                if (!nested) {
                    if (elided_stops(kind, prior, depth, targets, headed)) return false;
                }
            }

            if (emitter.elided_parted(scan, kind, prior)) return false;

            if (!is_layout(kind)) {
                if (kind != .comment) {
                    held = true;
                    prior = kind;
                }
            }
        }

        return held;
    }

    fn elided_parted(emitter: *const Emitter, position: u32, kind: Kind, prior: ?Kind) bool {
        assert(position > 0);
        assert(position < emitter.tokens.len);

        if (!is_string_start(kind)) return false;
        if (prior) |held| assert(held.is_token());

        const held = prior orelse return false;
        if (!kind_joined(held)) return false;

        const from = emitter.tokens[position - 1].end();
        const to = emitter.tokens[position].offset;
        if (blank_lines(emitter.source, from, to) == 0) return false;
        return emitter.part(position) == null;
    }

    pub fn next_kind(emitter: *const Emitter, position: u32) ?Kind {
        assert(position < emitter.tokens.len);
        assert(emitter.tokens.len == emitter.raw.len);

        const count: u32 = @intCast(emitter.tokens.len);
        var scan = position + 1;

        while (scan < count) : (scan += 1) {
            const kind = emitter.raw[scan];
            const indentation = kind == .dedent or kind == .indent;
            const significant = !indentation and emitter.tokens[scan].length > 0;
            if (significant) return kind;
        }

        return null;
    }

    fn run(emitter: *Emitter) error{Overflow}!void {
        assert(emitter.tokens.len == emitter.raw.len);
        assert(emitter.depth == 0);

        var wrote = false;

        for (0..emitter.tokens.len) |index| {
            const position: u32 = @intCast(index);

            try emitter.run_token(position, &wrote);
            try emitter.closes_powers(position);
        }

        try emitter.unjoin();

        const count: u32 = @intCast(emitter.tokens.len);

        if (emitter.wrap == count) try emitter.unwrap();

        try emitter.run_close(wrote);
    }

    fn run_token(emitter: *Emitter, position: u32, wrote: *bool) error{Overflow}!void {
        assert(position < emitter.tokens.len);
        assert(emitter.elisions <= bracket_depth_max);

        const kind = emitter.raw[position];

        if (position < emitter.until) return;

        if (emitter.skip == position) {
            emitter.skip = null;

            return;
        }

        if (emitter.elides(position, kind)) return emitter.run_elided(position);

        if (emitter.concat_at) |at| {
            if (position > at) try emitter.unjoin();
        }

        emitter.enjoin(position);

        if (try emitter.wide(position, kind)) {
            wrote.* = true;

            return;
        }

        if (kind == .comment) {
            if (emitter.skip == null) {
                if (emitter.hoist(position)) {
                    const hoisted = emitter.skip.?;

                    try emitter.indented(hoisted, emitter.column_after(hoisted));
                }
            }

            try emitter.lower(position);
        }

        return emitter.step(position, kind, wrote);
    }

    fn run_elided(emitter: *Emitter, position: u32) error{Overflow}!void {
        assert(position < emitter.tokens.len);
        assert(emitter.elisions <= bracket_depth_max);

        if (emitter.wrap != position) return;

        assert(emitter.raw[position] == .paren_close);
        if (emitter.concat_at) |at| assert(at < position);

        try emitter.unjoin();

        return emitter.unwrap();
    }

    fn run_close(emitter: *Emitter, wrote: bool) error{Overflow}!void {
        assert(emitter.depth <= bracket_depth_max);
        assert(emitter.indent <= bracket_depth_max);

        for (0..bracket_depth_max) |_| {
            if (emitter.depth == 0) break;

            emitter.depth -= 1;

            try emitter.document.push(.group_close);
            try emitter.document.push(.dedent);
            try emitter.document.push(.group_close);
        }

        for (0..bracket_depth_max) |_| {
            if (emitter.indent == 0) break;

            emitter.indent -= 1;

            try emitter.document.push(.dedent);
        }

        assert(emitter.depth == 0);
        assert(emitter.indent == 0);

        if (wrote) try emitter.document.push(.hard_line);
    }

    fn separator(emitter: *Emitter, position: u32, splits: bool) error{Overflow}!void {
        assert(position < emitter.tokens.len);
        assert(emitter.raw[position] == .comma);

        const held = emitter.frame();
        const outer = emitter.depth == 0 and emitter.wrap != null and splits;
        const subscripted = emitter.depth > 0 and held.kind == .bracket_open and held.call;

        if (subscripted) {
            if (emitter.at_lambda != emitter.depth) {
                const complex = slice.element_complex(emitter, position + 1);

                emitter.frames[emitter.depth - 1].complex = complex;
            }
        }

        if (outer) {
            const ends = emitter.wrap_ends(position);

            try emitter.text(position, false);
            try emitter.ends_element(0);

            if (ends) return;

            try emitter.document.push(.line);

            return emitter.starts_element(position, .comma, held.priority);
        }

        const flat = emitter.depth == 0 or !splits;

        if (flat) {
            try emitter.text(position, false);

            return emitter.wrapped(position, .comma);
        }

        const top = emitter.depth - 1;

        emitter.frames[top].annotated = false;
        emitter.frames[top].commas = true;

        if (emitter.trails(position)) {
            const magic = held.magic or (!emitter.magic_trailing_comma and held.magic_source);
            const dropped = magic and !emitter.commented(position);
            if (dropped) return;

            emitter.frames[top].trailed = true;

            return emitter.text(position, false);
        }

        const cap = held.priority;

        if (emitter.commented(position)) {
            try emitter.text(position, false);
            try emitter.ends_element(0);

            return emitter.starts_element(position, .comma, cap);
        }

        const line_element: Element = if (held.magic) .hard_line else .line;

        try emitter.text(position, false);
        try emitter.ends_element(0);
        try emitter.document.push(line_element);
        try emitter.starts_element(position, .comma, cap);
    }

    fn spaced(emitter: *const Emitter, current: Kind) bool {
        assert(current.is_token());
        assert(emitter.depth <= bracket_depth_max);

        const previous = emitter.previous orelse return false;

        if (emitter.suppress_space) return false;
        if (is_open(previous)) return false;

        if (current == .dot) {
            if (previous == .number_integer) return true;
            return !ends_operand(previous) and previous != .dot;
        }

        if (previous == .dot) return current == .import_keyword;

        if (previous == .ellipsis) {
            if (emitter.line_first == .from_keyword) return current == .import_keyword;
        }

        if (current == .colon) {
            const held = emitter.frame();
            const sliced = held.complex and held.kind == .bracket_open and held.call;

            if (emitter.at_lambda == emitter.depth) return false;
            return sliced and previous != .colon and !is_open(previous);
        }

        if (current == .comma) return false;
        if (current == .semicolon) return false;
        if (is_close(current)) return false;

        if (current == .star) {
            if (previous == .except_keyword) return false;
        }

        const opening = current == .bracket_open or current == .paren_open;

        if (opening) {
            const headed = emitter.soft_keyword() and
                onset.soft_header(emitter, emitter.at_previous.?);

            return headed or !ends_operand(previous);
        }

        return emitter.spaced_framed(current, previous);
    }

    fn spaced_framed(emitter: *const Emitter, current: Kind, previous: Kind) bool {
        assert(!is_open(previous));
        assert(!is_close(current));

        const held = emitter.frame();

        const sliced = previous == .colon and held.kind == .bracket_open and held.call and
            !emitter.lambda_colon_previous();

        if (sliced) return held.complex and current != .colon;

        const defaulted = previous == .equal or current == .equal;

        if (defaulted) {
            if (emitter.unspaced_default()) return false;
        }

        if (current == .star_star) {
            if (ends_operand(previous)) return !emitter.hugged;
        }

        return true;
    }

    pub fn closed_at(emitter: *const Emitter, position: u32) ?u32 {
        assert(position < emitter.tokens.len);
        assert(is_open(emitter.raw[position]));

        const count: u32 = @intCast(emitter.tokens.len);
        var depth: u32 = 0;
        var scan = position;

        while (scan < count) : (scan += 1) {
            const kind = emitter.raw[scan];

            if (is_open(kind)) depth += 1;

            if (is_close(kind)) {
                depth -= 1;

                if (depth == 0) return scan;
            }
        }

        return null;
    }

    pub fn text(emitter: *Emitter, position: u32, space: bool) error{Overflow}!void {
        assert(position < emitter.tokens.len);
        assert(emitter.parentheses.open != emitter.parentheses.close);

        const opens = power.powered(emitter, position, emitter.previous);

        try emitter.texted(position, space);

        if (opens) |held| try emitter.opens_power(position, held);
    }

    fn opens_power(emitter: *Emitter, position: u32, end: u32) error{Overflow}!void {
        assert(position < end);
        assert(end < emitter.tokens.len);

        const negated = emitter.raw[position] == .not_keyword;
        const literal = if (negated) emitter.parentheses.open else emitter.parentheses.head;

        return emitter.opens_virtual(position, end, literal);
    }

    fn opens_virtual(
        emitter: *Emitter,
        position: u32,
        end: u32,
        literal: u32,
    ) error{Overflow}!void {
        assert(position < end);
        assert(end < emitter.tokens.len);

        if (emitter.depth == bracket_depth_max) return error.Overflow;
        assert(literal <= literal_count_max);

        const head = emitter.document.literal_span(literal);
        var held: Frame = .new();

        held.kind = .paren_open;
        held.priority = emitter.priority_between(position + 1, end + 1);

        try emitter.powers.push(end);

        emitter.frames[emitter.depth] = held;
        emitter.depth += 1;
        emitter.suppress_space = true;

        try emitter.document.push(.group_open);
        try emitter.document.push(.{ .text = .{ .source = .literal, .span = head } });
        try emitter.document.push(.indent);
        try emitter.document.push(.soft_line);
        try emitter.document.push(.group_open);
        try emitter.starts_element_from(position + 1, .paren_open, held.priority);
    }

    fn closes_powers(emitter: *Emitter, position: u32) error{Overflow}!void {
        assert(position < emitter.tokens.len);
        assert(emitter.powers.count <= bracket_depth_max);

        if (!emitter.powers.ends_at(position)) return;

        if (emitter.concat_at == position) try emitter.unjoin();

        for (0..bracket_depth_max) |_| {
            if (!emitter.powers.closes(position)) break;

            const enclosed = emitter.wrap != null and emitter.wrap_depth >= emitter.depth;

            if (enclosed) try emitter.unwrap();

            const tail = emitter.document.literal_span(emitter.parentheses.close);

            assert(emitter.depth > 0);
            assert(emitter.frame().kind == .paren_open);

            try emitter.ends_element(0);

            emitter.depth -= 1;
            emitter.previous = .paren_close;

            try emitter.document.push(.group_close);
            try emitter.document.push(.dedent);
            try emitter.document.push(.soft_line);
            try emitter.document.push(.{ .text = .{ .source = .literal, .span = tail } });
            try emitter.document.push(.group_close);
        }
    }

    fn texted(emitter: *Emitter, position: u32, space: bool) error{Overflow}!void {
        assert(position < emitter.tokens.len);
        assert(emitter.tokens.len == emitter.raw.len);

        const kind = emitter.raw[position];
        const span = emitter.tokens[position].span();

        emitter.at_previous = position;

        if (space) try emitter.document.push(.space);

        if (onset.names_walrus(emitter, position)) {
            emitter.walrus = true;

            try emitter.document.push(.group_open);
        }

        try emitter.opens_join();

        emitter.suppress_space = emitter.suppresses(kind);

        if (kind != .comment) emitter.previous = kind;

        emitter.mark(kind);

        if (span.length == 0) return;
        return emitter.texted_span(position, kind, span);
    }

    fn texted_span(emitter: *Emitter, position: u32, kind: Kind, span: Span) error{Overflow}!void {
        assert(span.length > 0);
        assert(span.end() <= emitter.source.len);
        assert(position < emitter.tokens.len);
        assert(kind.is_token());

        if (kind == .comment) return emitter.texted_comment(span);

        const documenting = kind == .string_plain and docstrings.documents(emitter, position);

        if (documenting) {
            const top = emitter.indent == 0 and emitter.depth == 0;
            const extent = docstrings.extent(emitter, position);
            const tail = emitter.rider(extent.last) orelse extent.last;

            emitter.documented = top or docstrings.classes_above(emitter, extent.first);
            emitter.documented_past = emitter.indent == 0 and emitter.comments_trail(tail);

            return emitter.docstring(span);
        }

        const stringed = kind == .string_bytes or kind == .string_plain;

        if (stringed) {
            if (emitter.relit(span)) |held| {
                return emitter.document.push(.{ .text = .{ .source = .arena, .span = held } });
            }
        }

        if (is_number(kind)) {
            if (emitter.renumber(span)) |held| {
                return emitter.document.push(.{ .text = .{ .source = .arena, .span = held } });
            }
        }

        if (std.mem.findScalar(u8, span.text(emitter.source), '\n') != null) {
            return emitter.document.push(.{ .verbatim = span });
        }

        return emitter.document.push(.{ .text = .{ .source = .document, .span = span } });
    }

    fn texted_comment(emitter: *Emitter, span: Span) error{Overflow}!void {
        assert(span.length > 0);
        assert(span.end() <= emitter.source.len);

        const bytes = span.text(emitter.source);
        const last = bytes[bytes.len - 1];
        const blank_ended = last == ' ' or last == '\t';

        assert(bytes[0] == '#');

        if (emitter.comment_normalized(span)) |held| {
            if (blank_ended) return emitter.document.push(.{ .verbatim_arena = held });
            return emitter.document.push(.{ .text = .{ .source = .arena, .span = held } });
        }

        if (blank_ended) return emitter.document.push(.{ .verbatim = span });
        return emitter.document.push(.{ .text = .{ .source = .document, .span = span } });
    }

    fn docstring(emitter: *Emitter, span: Span) error{Overflow}!void {
        assert(span.length > 0);
        assert(span.end() <= emitter.source.len);

        const preference: QuotePreference = if (emitter.quote == .preserve) .preserve else .double;

        if (body_escaped(span.text(emitter.source))) {
            if (emitter.requote(span, preference)) |held| {
                return emitter.document.push(.{ .verbatim_arena = held });
            }

            return emitter.document.push(.{ .verbatim = span });
        }

        const held = emitter.reindented(span, preference) orelse {
            if (emitter.requote(span, preference)) |swapped| {
                return emitter.document.push(.{ .text = .{ .source = .arena, .span = swapped } });
            }

            return emitter.document.push(.{ .verbatim = span });
        };

        emitter.requote_arena(held, preference);

        return emitter.document.push(.{ .verbatim_arena = held });
    }

    fn requote_arena(emitter: *Emitter, held: Span, preference: QuotePreference) void {
        assert(held.length > 0);
        assert(held.end() <= emitter.arena.count());

        const bytes = held.text(emitter.arena.const_slice());
        const edges = quote_edges(bytes, held.offset, preference) orelse return;

        assert(edges.close + edges.quote.len == held.end());

        emitter.arena.patch(edges.at, edges.quote);
        emitter.arena.patch(edges.close, edges.quote);
    }

    fn reindented(emitter: *Emitter, span: Span, preference: QuotePreference) ?Span {
        assert(span.length > 0);
        assert(span.end() <= emitter.source.len);

        const bytes = span.text(emitter.source);
        const edges = body_edges(bytes) orelse return null;
        const offset = emitter.arena.count();

        emitter.reindented_write(bytes, edges, preference) catch |err| switch (err) {
            error.Overflow => {
                emitter.arena.truncate(offset);

                return null;
            },
        };

        assert(emitter.arena.count() > offset);

        return .{ .offset = offset, .length = emitter.arena.count() - offset };
    }

    fn reindented_write(
        emitter: *Emitter,
        bytes: []const u8,
        edges: Edges,
        preference: QuotePreference,
    ) error{Overflow}!void {
        assert(edges.head <= edges.tail);
        assert(edges.tail <= bytes.len);

        const offset = emitter.arena.count();
        const width = emitter.indent * emitter.indent_width;
        const body = bytes[edges.head..edges.tail];

        if (body.len > 0) {
            if (trim_ascii(body).len == 0) {
                try emitter.arena.push(bytes[0..edges.head]);
                try emitter.arena.push(" ");

                return emitter.arena.push(bytes[edges.tail..]);
            }
        }

        const common = body_indent(body);
        var lines = std.mem.splitScalar(u8, body, '\n');
        const first = trim_ascii(lines.first());
        const quote = settled(bytes, edges.head, ending_of(body, first, common), preference);
        var ends_open = false;

        try emitter.arena.push(bytes[0..edges.head]);

        const quoted_first = first.len > 0 and first[0] == quote;

        if (quoted_first) try emitter.arena.push(" ");

        try emitter.arena.push(first);

        if (common) |indent| ends_open = try emitter.reindented_lines(&lines, body, indent, width);

        const slashed = first.len > 0 and first[first.len - 1] == '\\';
        const continued = !ends_open and slashed and common == null;

        if (continued) {
            try emitter.arena.push("\n");

            for (0..width) |_| try emitter.arena.push(" ");

            ends_open = true;
        }

        const closing = emitter.arena.const_slice()[offset..];
        const quoted_last = closing.len > 0 and closing[closing.len - 1] == quote;
        const padded = !ends_open and first.len > 0 and (quoted_last or odd_slashes(closing));

        if (padded) try emitter.arena.push(" ");

        try emitter.arena.push(bytes[edges.tail..]);
    }

    fn reindented_lines(
        emitter: *Emitter,
        lines: *std.mem.SplitIterator(u8, .scalar),
        body: []const u8,
        common: u32,
        width: u32,
    ) error{Overflow}!bool {
        assert(common < body.len);
        assert(width == emitter.indent * emitter.indent_width);

        const count = std.mem.count(u8, body, "\n") + 1;
        var ends_open = false;

        for (0..count - 1) |index| {
            const line = lines.next().?;
            const kept = if (common <= line.len) line[common..] else line[line.len..];
            const stripped = std.mem.trimEnd(u8, kept, ascii_whitespace);

            try emitter.arena.push("\n");

            const last = index + 2 == count;

            if (stripped.len == 0) {
                if (!last) continue;
            }

            for (0..width) |_| try emitter.arena.push(" ");

            try emitter.arena.push(stripped);

            ends_open = stripped.len == 0;
        }

        assert(lines.index == null);

        return ends_open;
    }

    pub fn wraps(emitter: *const Emitter, position: u32, lambdaed: bool) bool {
        assert(position < emitter.tokens.len);
        assert(emitter.depth <= bracket_depth_max);

        if (!lambdaed) {
            if (emitter.depth > 0) return false;
            if (emitter.at_lambda != null) return false;
        }

        const end = emitter.wrap_end(position);

        if (lambdaed) {
            if (!emitter.wraps_lambda(end)) return false;
            if (onset.comments_body(emitter, position, end)) return true;
        }

        const contents = emitter.wraps_contents(position, end) orelse return false;
        if (!contents.held) return false;

        if (contents.commented) {
            if (!emitter.wrap_holds(position, end)) return false;
        }

        const operated = end < emitter.tokens.len and emitter.raw[end] == .comment and
            emitter.omits_split(position, end).found > priority_dot;

        if (!operated) {
            if (!emitter.wrap_rides(end)) return false;
        }

        const bound = emitter.wrap_bound(position, end);
        if (lambdaed) return !emitter.omits_body(position, bound, null);
        if (emitter.raw[position] == .arrow) return onset.returns_wrap(emitter, position, bound);

        if (emitter.raw[position] == .in_keyword) {
            if (!emitter.multiline(position, bound)) return onset.iterable_wraps(emitter, position);
        }

        if (emitter.message_parens(position, bound)) |first| {
            const close_at = emitter.closed_at(first).?;
            return !emitter.omits(first, close_at, first);
        }

        if (emitter.raw[position] == .with_keyword) {
            if (emitter.listed_line(position + 1, bound)) return true;
            if (onset.with_target(emitter, position, bound, null)) |omitted| return !omitted;
        }

        return !emitter.omits(position, bound, null);
    }

    fn multiline(emitter: *const Emitter, open_at: u32, ceiling: u32) bool {
        assert(open_at < ceiling);
        assert(ceiling <= emitter.tokens.len);

        const split = emitter.omits_split(open_at, ceiling);
        if (split.found > priority_dot) return true;
        return split.found == priority_dot and split.count > 1;
    }

    pub fn omits_body(emitter: *const Emitter, open_at: u32, ceiling: u32, dropped: ?u32) bool {
        assert(open_at < ceiling);
        assert(ceiling <= emitter.tokens.len);
        if (dropped) |held| assert(held == open_at);

        const split = emitter.omits_split(open_at, ceiling);
        const dotted = split.found == 0 or split.found == priority_dot;
        if (!dotted) return false;

        const first = emitter.next_token(open_at, ceiling) orelse return false;
        if (is_unary(emitter.raw[first])) return false;
        if (emitter.omits_whole(open_at, ceiling)) return true;

        const last = emitter.prior_token(ceiling, open_at) orelse return false;
        if (!is_close(emitter.raw[last])) return false;
        if (!emitter.splittable(open_at, ceiling)) return false;
        return emitter.omits_fitted(open_at, ceiling, dropped, false);
    }

    fn splittable(emitter: *const Emitter, open_at: u32, ceiling: u32) bool {
        assert(open_at < ceiling);
        assert(ceiling <= emitter.tokens.len);

        var depth: u32 = 0;
        var scan = open_at + 1;

        while (scan < ceiling) : (scan += 1) {
            const kind = emitter.raw[scan];

            if (is_close(kind)) depth -|= 1;

            if (is_open(kind)) {
                const held = emitter.next_token(scan, ceiling) orelse return false;
                const occupied = !is_close(emitter.raw[held]);

                if (depth == 0) {
                    if (occupied) return true;
                }

                depth += 1;
            }
        }

        return false;
    }

    fn message_parens(emitter: *const Emitter, position: u32, bound: u32) ?u32 {
        assert(position < bound);
        assert(bound <= emitter.tokens.len);

        if (emitter.raw[position] != .comma) return null;
        if (!emitter.messages(position)) return null;

        const first = emitter.next_token(position, bound) orelse return null;
        if (emitter.raw[first] != .paren_open) return null;

        const close_at = emitter.closed_at(first) orelse return null;
        const last = emitter.prior_token(bound, position) orelse return null;
        if (last != close_at) return null;
        if (!emitter.elided_body(first, close_at, .none, false)) return null;
        return first;
    }

    fn wraps_lambda(emitter: *const Emitter, end: u32) bool {
        assert(end <= emitter.tokens.len);
        assert(emitter.depth <= bracket_depth_max);

        if (emitter.depth > 0) return true;
        if (end == emitter.tokens.len) return true;
        if (emitter.raw[end] != .comma) return true;

        const at = emitter.line_first_at orelse return true;
        if (end <= at) return true;

        const width = emitter.indent * emitter.indent_width + emitter.measured(at, end - 1);
        return width > emitter.line_width;
    }

    fn wraps_contents(emitter: *const Emitter, position: u32, end: u32) ?WrapsContents {
        assert(position < end);
        assert(end <= emitter.tokens.len);

        return emitter.contents_from(position + 1, end);
    }

    pub fn contents_from(emitter: *const Emitter, from: u32, end: u32) ?WrapsContents {
        assert(from <= end);
        assert(end <= emitter.tokens.len);

        var contents: WrapsContents = .{ .held = false, .commented = false };
        var depth: u32 = 0;
        var format: u32 = 0;
        var scan = from;

        while (scan < end) : (scan += 1) {
            const kind = emitter.raw[scan];
            if (is_layout(kind)) continue;

            const spanning = kind == .f_string_middle or kind == .string_bytes or
                kind == .string_plain;

            const bytes = emitter.tokens[scan].text(emitter.source);

            if (!spanning) {
                if (std.mem.findScalar(u8, bytes, '\n') != null) return null;
            }

            if (kind == .f_string_start) format += 1;
            if (kind == .f_string_end) format -= 1;

            const inside = format > 0 and kind != .f_string_start;
            if (inside) continue;

            if (is_open(kind)) depth += 1;
            if (is_close(kind)) depth -|= 1;

            const leading = kind == .lambda_keyword and !contents.held;
            const stops = kind == .equal or kind == .semicolon or leading;

            if (depth == 0) {
                if (stops) return null;
            }

            contents.commented = contents.commented or kind == .comment;
            contents.held = contents.held or kind != .comment;
        }

        return contents;
    }

    fn wraps_chain(emitter: *const Emitter, position: u32, chained: u32) bool {
        assert(position < chained);
        assert(chained < emitter.tokens.len);

        if (emitter.target_bracket(emitter.wrap_end(position), null, false)) return false;

        const count: u32 = @intCast(emitter.tokens.len);
        var depth: u32 = 0;
        var scan = chained;

        while (scan < count) : (scan += 1) {
            const kind = emitter.raw[scan];
            if (ends_line(kind)) break;

            if (is_open(kind)) depth += 1;
            if (is_close(kind)) depth -|= 1;

            const assigns = depth == 0 and kind == .equal;

            if (assigns) {
                if (emitter.wrap_opens(scan, null)) return false;
            }
        }

        if (!emitter.wrap_opens(position, null)) return false;
        return !emitter.omits(position, chained, null);
    }

    fn wrap_bound(emitter: *const Emitter, position: u32, end: u32) u32 {
        assert(position < end);
        assert(end <= emitter.tokens.len);

        return emitter.bound_from(position + 1, end);
    }

    pub fn bound_from(emitter: *const Emitter, from: u32, end: u32) u32 {
        assert(from <= end);
        assert(end <= emitter.tokens.len);

        var scan = end;

        while (scan > from) : (scan -= 1) {
            const kind = emitter.raw[scan - 1];
            const trailing = is_layout(kind) or kind == .comment;
            if (!trailing) break;
        }

        assert(scan >= from);
        assert(scan <= end);

        return scan;
    }

    pub fn wrap_rides(emitter: *const Emitter, end: u32) bool {
        assert(end <= emitter.tokens.len);
        assert(emitter.indent <= bracket_depth_max);

        if (end == emitter.tokens.len) return true;
        if (emitter.raw[end] == .newline) return true;

        const riding = emitter.raw[end] == .comment;
        const comment_at: u32 = if (riding) end else (emitter.rider(end) orelse return true);
        const span = emitter.tokens[comment_at].span();
        const closing: u32 = if (riding) 3 else 4;
        const flat = emitter.indent * emitter.indent_width;
        const width = flat + closing + columns(emitter.source, span.offset, span.end());

        return width <= emitter.line_width;
    }

    pub fn lambdas(emitter: *const Emitter, position: u32) bool {
        assert(position < emitter.tokens.len);
        assert(emitter.tokens.len == emitter.raw.len);

        var depth: u32 = 0;
        var scan = position;

        while (scan > 0) {
            scan -= 1;

            const kind = emitter.raw[scan];

            if (is_close(kind)) {
                depth += 1;

                continue;
            }

            if (is_open(kind)) {
                if (depth == 0) return false;

                depth -= 1;

                continue;
            }

            if (depth > 0) continue;
            if (kind == .lambda_keyword) return true;

            const stops = is_layout(kind) or kind == .colon or kind == .comment or
                kind == .semicolon;

            if (stops) return false;
        }

        return false;
    }

    pub fn wrap_end(emitter: *const Emitter, position: u32) u32 {
        assert(position < emitter.tokens.len);
        assert(emitter.tokens.len == emitter.raw.len);

        const kind = emitter.raw[position];
        const lambdaed = kind == .colon and emitter.lambdas(position);
        const head: Kind = if (lambdaed) .lambda_keyword else kind;
        const returned = emitter.wrap_end_from(position + 1, head);

        assert(returned < std.math.maxInt(u32));

        return returned;
    }

    pub fn wrap_end_from(emitter: *const Emitter, from: u32, head: ?Kind) u32 {
        assert(from <= emitter.tokens.len);
        if (head) |known| assert(known.is_token());

        const count: u32 = @intCast(emitter.tokens.len);
        var depth: u32 = 0;
        var ellipsis = false;
        var pending: u32 = 0;
        var scan = from;
        var words: u32 = 0;

        while (scan < count) {
            const kind = emitter.raw[scan];
            if (ends_line(kind)) return scan;

            const bodied = depth == 0 and kind == .colon and pending > 0;

            if (bodied) pending -= 1;

            const topmost = depth == 0 and !bodied;

            if (topmost) {
                const forward = kind == .async_keyword and emitter.next_kind(scan) == .for_keyword;
                const clause = kind == .for_keyword or forward;
                const counted = words + @intFromBool(ellipsis);

                if (wrap_end_stops(head, kind, clause, counted)) {
                    if (!onset.comment_inside(emitter, scan, head)) return scan;
                }

                if (kind == .lambda_keyword) {
                    if (words > 0) pending += 1;
                }
            }

            if (kind == .f_string_start) {
                words += 1;
                scan = emitter.format_end(scan) + 1;

                continue;
            }

            const counted = !is_layout(kind) and kind != .comment;

            if (counted) {
                ellipsis = words == 0 and kind == .ellipsis;
                words += 1;
            }

            if (is_open(kind)) depth += 1;
            if (is_close(kind)) depth -|= 1;

            scan += 1;
        }

        assert(scan == count);

        return count;
    }

    pub fn wrap_line(emitter: *Emitter, position: u32) error{Overflow}!void {
        assert(position < emitter.tokens.len);
        assert(emitter.wrap == null);

        const end = emitter.wrap_end(position);
        const parens = emitter.message_parens(position, emitter.wrap_bound(position, end));
        const from = if (parens) |first| first + 1 else position + 1;
        const sole = emitter.listed_line(from, end) or emitter.line_first == .from_keyword;
        const tuple = emitter.tupled_line(from, end);

        return emitter.wrapping(from, emitter.raw[position], end, sole, tuple, false);
    }

    pub fn wrapping(
        emitter: *Emitter,
        from: u32,
        previous: ?Kind,
        end: u32,
        sole: bool,
        tuple: bool,
        heads: bool,
    ) error{Overflow}!void {
        assert(from <= end);
        assert(end <= emitter.tokens.len);
        if (previous) |held| assert(held.is_token());

        const literal = if (heads) emitter.parentheses.head else emitter.parentheses.open;
        const open_span = emitter.document.literal_span(literal);
        const headed = heads and !tuple;

        emitter.wrap = end;
        emitter.wrap_depth = emitter.depth;
        emitter.wrap_headed = headed;
        emitter.wrap_sole = sole;
        emitter.wrap_tuple = tuple;

        const priority = emitter.priority_between(from, end);

        emitter.wrapper = .new();
        emitter.wrapper.priority = priority;

        if (emitter.depth > 0) emitter.isolates(priority);

        const literal_element: Element = .{ .text = .{ .source = .literal, .span = open_span } };
        const head_element: Element = if (tuple) literal_element else .{ .if_broken = open_span };
        const edge: Element = if (tuple and sole) .hard_line else .soft_line;

        emitter.suppress_space = emitter.suppress_space or tuple;

        try emitter.document.push(.group_open);
        try emitter.document.push(head_element);
        try emitter.document.push(if (headed) .indent_broken else .indent);
        try emitter.document.push(edge);

        if (!sole) try emitter.document.push(.group_open);

        try emitter.starts_element_from(from, previous, priority);
    }

    fn isolates(emitter: *Emitter, priority: u8) void {
        assert(emitter.depth > 0);
        assert(emitter.wrap != null);

        const top = emitter.depth - 1;
        var held = emitter.frames[top];

        emitter.wrap_outer = held;
        held.group_count = 0;
        held.level_count = 0;
        held.levels = @splat(0);
        held.priority = priority;
        held.splits = .new();
        emitter.frames[top] = held;

        assert(emitter.frame().level_count == 0);
    }

    fn rejoins(emitter: *Emitter) void {
        assert(emitter.wrap_depth > 0);
        assert(emitter.depth == emitter.wrap_depth);

        const top = emitter.wrap_depth - 1;
        const outer = emitter.wrap_outer;
        var held = emitter.frames[top];

        assert(held.level_count == 0);

        held.group_count = outer.group_count;
        held.level_count = outer.level_count;
        held.levels = outer.levels;
        held.priority = outer.priority;
        held.splits = outer.splits;
        emitter.frames[top] = held;
        emitter.wrap_outer = .new();
    }

    fn wrap_ends(emitter: *const Emitter, position: u32) bool {
        assert(position < emitter.tokens.len);
        assert(emitter.wrap != null);

        const count: u32 = @intCast(emitter.tokens.len);
        const stop = @min(count, emitter.wrap.?);
        var scan = position + 1;

        while (scan < stop) : (scan += 1) {
            const kind = emitter.raw[scan];
            const trailing = is_layout(kind) or kind == .comment;
            if (!trailing) return false;
        }

        return true;
    }

    pub fn tupled_line(emitter: *const Emitter, from: u32, stop: u32) bool {
        assert(from <= emitter.tokens.len);
        assert(stop <= emitter.tokens.len);

        const count = @min(@as(u32, @intCast(emitter.tokens.len)), stop);
        var depth: u32 = 0;
        var pending: u32 = 0;
        var previous: ?Kind = null;
        var scan = from;

        while (scan < count) : (scan += 1) {
            const kind = emitter.raw[scan];
            const bodied = depth == 0 and kind == .colon and pending > 0;
            const ends = ends_line(kind) or (depth == 0 and kind == .colon and !bodied);
            if (ends) break;

            if (bodied) pending -= 1;
            if (is_open(kind)) depth += 1;
            if (is_close(kind)) depth -|= 1;

            const skipped = is_layout(kind) or kind == .comment;
            if (skipped) continue;

            if (depth == 0) {
                if (kind == .lambda_keyword) pending += 1;
            }

            previous = kind;
        }

        return previous == .comma;
    }

    pub fn listed_line(emitter: *const Emitter, from: u32, stop: u32) bool {
        assert(from <= emitter.tokens.len);
        assert(stop <= emitter.tokens.len);

        const count = @min(@as(u32, @intCast(emitter.tokens.len)), stop);
        var commas: u32 = 0;
        var depth: u32 = 0;
        var pending: u32 = 0;
        var previous: ?Kind = null;
        var scan = from;

        while (scan < count) : (scan += 1) {
            const kind = emitter.raw[scan];
            const bodied = depth == 0 and kind == .colon and pending > 0;
            const ends = ends_line(kind) or (depth == 0 and kind == .colon and !bodied);
            if (ends) break;

            if (bodied) pending -= 1;
            if (is_open(kind)) depth += 1;
            if (is_close(kind)) depth -|= 1;

            const skipped = is_layout(kind) or kind == .comment;
            if (skipped) continue;

            if (depth == 0) {
                if (kind == .lambda_keyword) pending += 1;
            }

            commas += @intFromBool(depth == 0 and kind == .comma and pending == 0);
            previous = kind;
        }

        assert(commas <= count -| from);

        return commas > @intFromBool(previous == .comma);
    }

    fn unwrap(emitter: *Emitter) error{Overflow}!void {
        assert(emitter.wrap != null);
        assert(emitter.depth <= bracket_depth_max);

        const end = emitter.wrap.?;

        try emitter.ends_element(0);

        if (emitter.wrap_depth > 0) emitter.rejoins();

        const close_span = emitter.document.literal_span(emitter.parentheses.close);
        const comma_span = emitter.document.literal_span(emitter.literals.comma);
        const headed = emitter.wrap_headed;
        const tuple = emitter.wrap_tuple;
        const sole = emitter.wrap_sole;
        const trailed = emitter.previous == .comma;

        emitter.wrap = null;
        emitter.wrap_headed = false;
        emitter.wrap_sole = false;
        emitter.wrap_tuple = false;
        emitter.wrapper = .new();

        const literal_element: Element = .{ .text = .{ .source = .literal, .span = close_span } };
        const tail_element: Element = if (tuple) literal_element else .{ .if_broken = close_span };
        const owed = sole and !trailed;

        if (owed) assert(!emitter.comments_before(end));
        if (tuple) emitter.previous = .paren_close;
        if (!sole) try emitter.document.push(.group_close);
        if (owed) try emitter.document.push(.{ .if_broken = comma_span });

        try emitter.document.push(if (headed) .dedent_broken else .dedent);
        try emitter.document.push(.soft_line);
        try emitter.document.push(tail_element);
        try emitter.document.push(.group_close);
    }

    fn comments_before(emitter: *const Emitter, end: u32) bool {
        assert(end <= emitter.tokens.len);
        assert(emitter.tokens.len == emitter.raw.len);

        const last = emitter.prior_token(end, 0) orelse return false;
        return emitter.raw[last] == .comment;
    }

    fn parameterised(emitter: *const Emitter) bool {
        assert(emitter.tokens.len == emitter.raw.len);
        assert(emitter.depth <= bracket_depth_max);

        const at = emitter.at_previous orelse return false;

        if (emitter.previous != .identifier) return false;

        if (at > 0) {
            const before = emitter.raw[at - 1];
            const defined = before == .class_keyword or before == .def_keyword;
            if (defined) return true;
        }

        if (at != emitter.line_first_at.? + 1) return false;
        if (emitter.line_first != .identifier) return false;

        const first = emitter.tokens[emitter.line_first_at.?];
        return std.mem.eql(u8, first.text(emitter.source), "type");
    }

    pub fn soft_keyword(emitter: *const Emitter) bool {
        assert(emitter.tokens.len == emitter.raw.len);
        assert(emitter.depth <= bracket_depth_max);

        if (emitter.previous != .identifier) return false;
        if (emitter.at_previous != emitter.line_first_at) return false;

        const bytes = emitter.tokens[emitter.at_previous.?].text(emitter.source);
        return std.mem.eql(u8, bytes, "case") or std.mem.eql(u8, bytes, "match");
    }

    fn suppresses(emitter: *const Emitter, kind: Kind) bool {
        assert(kind.is_token());
        assert(emitter.depth <= bracket_depth_max);

        const prior_operand = if (emitter.previous) |prior| ends_operand(prior) else false;

        const operand = prior_operand and !onset.soft_headed(
            emitter,
        );

        if (kind == .star_star) return emitter.hugged or !operand;
        if (is_open(kind)) return true;
        if (kind == .dot) return operand;

        if (kind == .star) {
            if (emitter.previous == .except_keyword) return false;
        }

        if (kind == .at) {
            if (emitter.starting) return true;
        }

        const held = emitter.frame();

        if (kind == .colon) {
            const sliced = held.kind == .bracket_open and held.call;

            if (sliced) {
                if (emitter.at_lambda == emitter.depth) return false;
                return !held.complex;
            }
        }

        if (kind == .equal) {
            if (emitter.unspaced_default()) return true;
        }

        const prefix = kind == .at or kind == .minus or kind == .plus or kind == .star or
            kind == .tilde;

        const leading = emitter.starting and emitter.depth == 0 and emitter.elisions == 0;
        return prefix and (leading or !operand);
    }

    fn lambda_colon_previous(emitter: *const Emitter) bool {
        assert(emitter.depth <= bracket_depth_max);
        assert(emitter.previous == .colon);

        const at = emitter.at_previous orelse return false;
        if (emitter.raw[at] != .colon) return false;
        return slice.lambda_colon(emitter, at);
    }

    fn parametric(emitter: *const Emitter) bool {
        assert(emitter.depth <= bracket_depth_max);
        if (emitter.at_lambda) |at| assert(at <= bracket_depth_max);

        if (emitter.depth == 0) return false;
        if (emitter.at_lambda != null) return false;

        const held = emitter.frame();
        return held.kind == .paren_open and held.call;
    }

    fn unspaced_default(emitter: *const Emitter) bool {
        assert(emitter.depth <= bracket_depth_max);
        if (emitter.at_lambda) |at| assert(at <= bracket_depth_max);

        if (emitter.at_lambda != null) return true;

        const held = emitter.frame();
        return held.kind == .paren_open and held.call and !held.annotated;
    }

    fn token(emitter: *Emitter, position: u32, kind: Kind) error{Overflow}!void {
        assert(position < emitter.tokens.len);
        assert(emitter.raw[position] == kind);

        if (kind == .comment) {
            if (emitter.hoisting()) emitter.pending_break = true;
        }

        const own_line = emitter.pending_break or emitter.previous == null;

        try emitter.heading(position, kind, own_line);

        emitter.starting = own_line;

        if (kind == .comment) return emitter.comment(position, own_line);

        const suited = kind == .colon and emitter.depth == 0 and emitter.at_lambda == null;

        if (suited) {
            if (try emitter.suite(position)) return;
        }

        if (kind == .semicolon) {
            const trailed = emitter.commented(position);

            emitter.at_previous = position;
            emitter.pending_break = !opens_suite(emitter.line_first) and !trailed;

            return;
        }

        if (kind == .star_star) emitter.hugged = power.hugs(emitter, position);

        const stepped = emitter.parting(kind);
        const priority: u8 = if (emitter.keyed(position)) 0 else stepped;

        if (emitter.defers(position, kind, priority)) {
            emitter.pending_word = .{ .position = position, .priority = priority };

            return;
        }

        if (kind == .comma) return emitter.separator(position, priority == priority_comma);

        if (is_open(kind)) {
            if (emitter.spaced(kind)) try emitter.document.push(.space);

            return emitter.open(position, kind);
        }

        if (is_close(kind)) return emitter.close(position, kind);
        return emitter.token_parted(position, kind, priority, own_line);
    }

    fn token_parted(
        emitter: *Emitter,
        position: u32,
        kind: Kind,
        priority: u8,
        own_line: bool,
    ) error{Overflow}!void {
        assert(position < emitter.tokens.len);
        assert(!is_open(kind));
        assert(priority <= priority_comprehension);

        if (emitter.parts(priority)) |kept| {
            const hard = emitter.parted_join(position) or emitter.hug_breaks(position);
            const soft: Element = if (emitter.spaced(kind)) .line else .soft_line;
            const line_element: Element = if (hard) .hard_line else soft;
            const from = (emitter.rider(position) orelse position) + 1;

            try emitter.ends_element(kept);

            if (!own_line) try emitter.document.push(line_element);

            try emitter.starts_element_from(from, kind, priority);
            try emitter.text(position, false);

            const spaced_power = kind == .star_star and emitter.hugged and
                emitter.next_kind(from - 1) != .comment;

            if (spaced_power) {
                const spacer_span = emitter.document.literal_span(emitter.literals.spacer);

                try emitter.document.push(.{ .if_broken = spacer_span });
            }

            return emitter.wrapped(position, kind);
        }

        if (emitter.parted_join(position)) {
            try emitter.document.push(.hard_line);
            try emitter.text(position, false);

            return emitter.wrapped(position, kind);
        }

        const space = emitter.spaced(kind) or emitter.slices(position, kind);
        const walrused = kind == .colon_equal and emitter.walrus;

        if (walrused) {
            emitter.walrus = false;

            try emitter.document.push(.line);
            try emitter.document.push(.group_close);
            try emitter.text(position, false);

            return emitter.wrapped(position, kind);
        }

        const resumed = emitter.continued and kind == .identifier;
        if (resumed) return emitter.continuing(position);

        const defaulted = kind == .equal and emitter.parametric() and emitter.frame().annotated;

        if (defaulted) try emitter.ends_element(0);

        try emitter.text(position, space);

        if (defaulted) try emitter.starts_element(position, kind, emitter.frame().priority);
        if (onset.continues(emitter, position)) emitter.continued = true;

        return emitter.wrapped(position, kind);
    }

    fn continuing(emitter: *Emitter, position: u32) error{Overflow}!void {
        assert(emitter.continued);
        assert(emitter.raw[position] == .identifier);

        const span = emitter.document.literal_span(emitter.literals.continuation);
        const first = emitter.previous != .comma;

        try emitter.document.push(.{ .text = .{ .source = .literal, .span = span } });

        if (first) try emitter.document.push(.indent);

        try emitter.document.push(.hard_line);
        try emitter.text(position, false);

        if (emitter.next_kind(position) == .comma) return;

        emitter.continued = false;

        try emitter.document.push(.dedent);
    }

    fn parted_join(emitter: *const Emitter, position: u32) bool {
        assert(position < emitter.tokens.len);
        assert(emitter.tokens.len == emitter.raw.len);

        if (emitter.concat_at != null) return false;

        const at = emitter.at_previous orelse return false;

        if (!is_string_start(emitter.raw[position])) return false;

        const held = emitter.previous orelse return false;
        if (!kind_joined(held)) return false;

        var scan = at + 1;

        while (scan < position) : (scan += 1) {
            if (emitter.raw[scan] == .newline) return false;
        }

        const from = emitter.tokens[at].end();
        const to = emitter.tokens[position].offset;

        return blank_lines(emitter.source, from, to) > 0;
    }

    fn slices(emitter: *const Emitter, position: u32, kind: Kind) bool {
        assert(position < emitter.tokens.len);
        assert(emitter.raw[position] == kind);

        if (kind != .colon) return false;
        if (emitter.previous != .colon) return false;

        const held = emitter.frame();
        const sliced = held.call and held.complex and held.kind == .bracket_open;
        if (!sliced) return false;
        return emitter.next_kind(position) == .bracket_close;
    }

    pub fn heading(
        emitter: *Emitter,
        position: u32,
        kind: Kind,
        own_line: bool,
    ) error{Overflow}!void {
        assert(position < emitter.tokens.len);
        assert(emitter.raw[position] == kind);

        if (kind == .comment) {
            const hollowed = emitter.hollows(position, own_line);
            const operator = emitter.part_before(position);
            const strung = if (operator) |at| emitter.concats_before(at) else false;
            const alone = (own_line or emitter.heads_line(position)) and !strung;
            const before = if (alone) emitter.interruption(position) else 0;
            const after = if (strung) 0 else onset.ridden(emitter, position);
            const interrupted = @max(before, after);

            try emitter.closes_deferred(hollowed, interrupted);

            if (own_line) try emitter.separates(position);
        }

        if (emitter.pending_break) try emitter.break_line(position);

        const stands = own_line and kind == .comment and emitter.pending_word != null and
            !emitter.hoisting();

        if (stands) {
            try emitter.deferred();
            try emitter.document.push(.hard_line);
        }

        const reopens = own_line and kind != .comment and emitter.concat_at == null;
        const head = if (emitter.pending_word) |word| word.position else position;

        if (reopens) try emitter.opens_deferred(emitter.interruption(head));
        if (kind != .comment) try emitter.deferred();

        const headed = own_line and emitter.depth == 0 and emitter.elisions == 0;

        if (headed) {
            emitter.elided_line = .empty;
            emitter.line_depth = emitter.indent;
            emitter.line_first = kind;
            emitter.line_first_at = position;

            if (emitter.stub) stub_file.record(emitter, position);

            const targeted = emitter.wrap == null and kind != .comment;

            if (targeted) try emitter.wrap_target(position);
        }
    }

    fn deferred(emitter: *Emitter) error{Overflow}!void {
        assert(emitter.depth <= bracket_depth_max);
        if (emitter.pending_word) |word| assert(word.position < emitter.tokens.len);

        const held = emitter.pending_word orelse return;

        assert(held.priority > 0);

        emitter.pending_word = null;

        return emitter.token_parted(held.position, emitter.raw[held.position], held.priority, true);
    }

    fn defers(emitter: *const Emitter, position: u32, kind: Kind, priority: u8) bool {
        assert(position < emitter.tokens.len);
        assert(emitter.raw[position] == kind);

        if (emitter.pending_word != null) return false;
        if (emitter.depth == 0) return false;
        if (priority == 0) return false;
        if (priority == priority_comma) return false;
        if (ends_operand(kind)) return false;
        if (is_open(kind)) return false;
        if (emitter.concats_before(position)) return false;
        if (emitter.rider(position) != null) return true;
        return priority == priority_ternary and emitter.comments_from(position + 1);
    }

    fn hoisting(emitter: *const Emitter) bool {
        const word = emitter.pending_word orelse return false;

        assert(word.position < emitter.tokens.len);

        return word.priority == priority_ternary;
    }

    pub fn interruption(emitter: *const Emitter, position: u32) u8 {
        assert(position < emitter.tokens.len);

        if (emitter.hoisting()) return priority_ternary;

        const kind = emitter.raw[position];
        const keyword = kind == .if_keyword or kind == .else_keyword;
        const prior = emitter.prior_token(position, 0);
        const noted = if (prior) |at| emitter.raw[at] == .comment else false;

        if (keyword) {
            if (noted) {
                var held = emitter.splits_held();
                if (held.step(kind, emitter.previous) == priority_ternary) return priority_ternary;
            }
        }

        return emitter.interrupting(position);
    }

    fn part_start(emitter: *const Emitter, end: u32) u32 {
        assert(end < emitter.tokens.len);
        assert(emitter.tokens.len == emitter.raw.len);

        if (emitter.raw[end] != .f_string_end) return end;

        var depth: u32 = 0;
        var scan = end;

        while (scan > 0) {
            scan -= 1;

            const kind = emitter.raw[scan];

            if (kind == .f_string_end) depth += 1;

            if (kind == .f_string_start) {
                if (depth == 0) return scan;

                depth -= 1;
            }
        }

        return end;
    }

    pub fn part_before(emitter: *const Emitter, position: u32) ?u32 {
        assert(position < emitter.tokens.len);
        assert(emitter.tokens.len == emitter.raw.len);

        var scan = position;

        for (0..position) |_| {
            const held = emitter.prior_token(scan, 0) orelse return null;

            assert(held < scan);

            if (emitter.raw[held] != .comment) return held;

            scan = held;
        }

        return null;
    }

    fn concats_before(emitter: *const Emitter, position: u32) bool {
        assert(position < emitter.tokens.len);
        assert(emitter.tokens.len == emitter.raw.len);

        const last = emitter.part_before(position) orelse return false;
        if (!kind_joined(emitter.raw[last])) return false;

        const prior = emitter.part_before(emitter.part_start(last)) orelse return false;
        return kind_joined(emitter.raw[prior]);
    }

    fn parts(emitter: *const Emitter, priority: u8) ?u32 {
        assert(priority <= priority_comprehension);
        assert(emitter.depth <= bracket_depth_max);

        if (priority == 0) return null;
        if (priority == priority_comma) return null;

        const held = emitter.frame();

        assert(held.level_count <= element_depth_max);

        if (priority == held.priority) return 0;

        for (held.levels[0..held.level_count], 0..) |level, index| {
            if (level == priority) {
                assert(index + 1 <= emitter.tokens.len);

                return @intCast(index + 1);
            }
        }

        return null;
    }

    fn wrapped(emitter: *Emitter, position: u32, kind: Kind) error{Overflow}!void {
        assert(position < emitter.tokens.len);
        assert(emitter.raw[position] == kind);

        if (kind == .for_keyword) {
            if (emitter.depth > 0) {
                if (onset.single_target(emitter, position)) |comma_at| {
                    return emitter.opens_virtual(position, comma_at, emitter.parentheses.open);
                }
            }
        }

        if (emitter.wrap != null) return;
        if (kind == .identifier) return onset.wrap_pattern(emitter, position);
        if (try interpolated.wrapped(emitter, position, kind)) return;

        const after_async = position > 0 and emitter.raw[position - 1] == .async_keyword;
        const opener = emitter.line_first_at == position or after_async;
        const lambdaed = kind == .colon and emitter.lambdas(position);
        const annotated = kind == .colon and !lambdaed and onset.annotation_only(emitter, position);

        if (onset.annotated_wrap(emitter, position, kind)) |equal_at| {
            return emitter.wrapping(position + 1, kind, equal_at, false, false, false);
        }

        if (!annotated) {
            if (!emitter.wrapped_gates(kind, opener, lambdaed)) return;
        }

        if (onset.lambda_header(emitter, position, kind)) |end| {
            return emitter.opens_virtual(position, end, emitter.parentheses.open);
        }

        if (onset.lambda_enclosed(emitter, position, kind)) return;

        const assigns = kind == .equal and emitter.depth == 0;
        const chained = if (assigns) emitter.target_end(position + 1) else null;

        if (chained) |chain| {
            if (emitter.tupled_line(position + 1, chain)) {
                const sole = emitter.listed_line(position + 1, chain);
                return emitter.wrapping(position + 1, kind, chain, sole, true, false);
            }

            if (emitter.wraps_chain(position, chain)) {
                return emitter.wrapping(position + 1, kind, chain, false, false, false);
            }
        }

        if (kind != .yield_keyword) {
            if (emitter.next_kind(position) == .yield_keyword) return;
        }

        const end = emitter.wrap_end(position);
        const targeted = kind == .for_keyword and opener;

        if (kind == .await_keyword) {
            if (!emitter.primary_between(position + 1, end)) return;
        }

        if (!emitter.wrapped_tupled(position, kind, end, chained)) {
            if (targeted) return onset.wrap_target(emitter, position, end);
            if (!emitter.wraps(position, lambdaed)) return;
        }

        return emitter.wrap_line(position);
    }

    fn wrapped_gates(emitter: *const Emitter, kind: Kind, opener: bool, lambdaed: bool) bool {
        assert(kind.is_token());
        if (lambdaed) assert(kind == .colon);

        if (lambdaed) return true;
        if (is_augmented(kind)) return true;

        switch (kind) {
            .equal, .return_keyword, .yield_keyword => return true,
            .arrow => return emitter.depth == 0,
            .comma => return emitter.depth == 0 and emitter.line_first == .assert_keyword,
            .if_keyword => return opener or onset.guards(emitter, emitter.at_previous.?),
            .import_keyword => return emitter.line_first == .from_keyword,
            .in_keyword => return emitter.depth == 0 and emitter.iterates(),
            .assert_keyword,
            .await_keyword,
            .del_keyword,
            .elif_keyword,
            .except_keyword,
            .for_keyword,
            .while_keyword,
            .with_keyword,
            => return opener,
            else => return false,
        }
    }

    fn iterates(emitter: *const Emitter) bool {
        assert(emitter.depth <= bracket_depth_max);
        assert(emitter.tokens.len == emitter.raw.len);

        const at = emitter.line_first_at orelse return false;
        if (emitter.raw[at] == .for_keyword) return true;
        if (emitter.raw[at] != .async_keyword) return false;

        const next = emitter.next_token(at, @intCast(emitter.tokens.len)) orelse return false;
        return emitter.raw[next] == .for_keyword;
    }

    pub fn primary_between(emitter: *const Emitter, from: u32, to: u32) bool {
        assert(from <= to);
        assert(to <= emitter.tokens.len);

        var depth: u32 = 0;
        var scan = from;

        while (scan < to) : (scan += 1) {
            const kind = emitter.raw[scan];

            if (is_open(kind)) depth += 1;
            if (is_close(kind)) depth -|= 1;
            if (depth > 0) continue;

            if (kind == .f_string_start) {
                scan = emitter.format_end(scan);

                continue;
            }

            const trivia = is_layout(kind) or kind == .comment;
            const primary = ends_operand(kind) or kind == .dot or trivia;
            if (!primary) return false;
        }

        return true;
    }

    fn wrapped_tupled(
        emitter: *const Emitter,
        position: u32,
        kind: Kind,
        end: u32,
        chained: ?u32,
    ) bool {
        assert(position < emitter.tokens.len);
        assert(end <= emitter.tokens.len);

        if (emitter.depth > 0) return false;
        if (emitter.tupled_line(position + 1, end)) return true;
        assert(kind.is_token());

        if (kind == .yield_keyword) return emitter.listed_line(position + 1, end);
        if (kind != .equal) return false;
        if (chained != null) return false;
        if (!emitter.listed_line(position + 1, end)) return false;
        return emitter.wraps_wide(end);
    }

    fn target_end(emitter: *const Emitter, position: u32) ?u32 {
        assert(position <= emitter.tokens.len);
        assert(emitter.tokens.len == emitter.raw.len);

        const count: u32 = @intCast(emitter.tokens.len);
        var depth: u32 = 0;
        var scan = position;

        while (scan < count) : (scan += 1) {
            const kind = emitter.raw[scan];
            const ends = ends_line(kind) or (depth == 0 and kind == .colon);
            if (ends) return null;

            const assigns = depth == 0 and kind == .equal;
            if (assigns) return scan;

            if (is_open(kind)) depth += 1;
            if (is_close(kind)) depth -|= 1;
        }

        return null;
    }

    fn wrap_target(emitter: *Emitter, position: u32) error{Overflow}!void {
        assert(position < emitter.tokens.len);
        assert(emitter.wrap == null);

        const end = emitter.target_end(position) orelse return emitter.wrap_bare(position);
        const sole = emitter.listed_line(position, end);

        if (!emitter.tupled_line(position, end)) {
            if (!sole) return;
            if (!emitter.targets_wide(end)) return;
        }

        return emitter.wrapping(position, null, end, sole, true, true);
    }

    fn wrap_bare(emitter: *Emitter, position: u32) error{Overflow}!void {
        assert(position < emitter.tokens.len);
        assert(emitter.wrap == null);

        const kind = emitter.raw[position];
        const operand = ends_operand(kind) or is_open(kind) or kind == .f_string_start;
        const prefixed = is_unary(kind) or kind == .await_keyword or kind == .star;
        const bare = operand or prefixed;
        if (!bare) return;
        if (onset.soft_header(emitter, position)) return;

        const end = emitter.wrap_end_from(position, null);
        const sole = emitter.listed_line(position, end);

        if (!emitter.tupled_line(position, end)) {
            if (!sole) return onset.wrap_arithmetic(emitter, position, end);
            if (!emitter.wraps_wide(end)) return;
        }

        return emitter.wrapping(position, null, end, sole, true, true);
    }

    pub fn wraps_wide(emitter: *const Emitter, end: u32) bool {
        assert(end <= emitter.tokens.len);
        assert(emitter.indent <= bracket_depth_max);

        const width = if (emitter.line_first_at) |at| emitter.measured_line(at, end) else 0;
        return emitter.indent * emitter.indent_width + width > emitter.line_width;
    }

    fn targets_wide(emitter: *const Emitter, end: u32) bool {
        assert(end <= emitter.tokens.len);
        assert(emitter.indent <= bracket_depth_max);

        const width = if (emitter.line_first_at) |at| emitter.measured_line(at, end) else 0;
        return emitter.indent * emitter.indent_width + width + 2 > emitter.line_width;
    }

    fn commented(emitter: *const Emitter, position: u32) bool {
        assert(position < emitter.tokens.len);
        assert(emitter.tokens.len == emitter.raw.len);

        return emitter.rider(position) != null;
    }

    pub fn rider(emitter: *const Emitter, position: u32) ?u32 {
        assert(position < emitter.tokens.len);
        assert(emitter.tokens.len == emitter.raw.len);

        const count: u32 = @intCast(emitter.tokens.len);
        const from = emitter.tokens[position].end();
        var scan = position + 1;

        while (scan < count) : (scan += 1) {
            const kind = emitter.raw[scan];

            if (kind == .comment) {
                const to = emitter.tokens[scan].offset;
                if (std.mem.findScalar(u8, emitter.source[from..to], '\n') != null) return null;
                assert(scan <= emitter.tokens.len);

                return scan;
            }

            if (!is_layout(kind)) return null;
        }

        return null;
    }

    fn trails(emitter: *const Emitter, position: u32) bool {
        assert(position < emitter.tokens.len);
        assert(emitter.raw[position] == .comma);

        if (emitter.powers.ends_at(position)) return true;

        const count: u32 = @intCast(emitter.tokens.len);
        const riding = emitter.commented(position);
        var scan = position + 1;

        while (scan < count) : (scan += 1) {
            const kind = emitter.raw[scan];
            if (is_layout(kind)) continue;

            if (kind == .comment) {
                if (riding) continue;
            }

            return is_close(kind);
        }

        return false;
    }
};

const Pragma = @import("pragma.zig").Pragma;

const JoinMarks = struct {
    bytes: bool,
    format: bool,
    template: bool,
};

const LineElisions = struct {
    count: u32,
    positions: [elided_line_max]u32,

    const empty: LineElisions = .{ .count = 0, .positions = @splat(0) };

    fn holds(elisions: *const LineElisions, position: u32) bool {
        assert(elisions.count <= elided_line_max);
        assert(position < std.math.maxInt(u32));

        return std.mem.findScalar(u32, elisions.positions[0..elisions.count], position) != null;
    }

    fn record(elisions: *LineElisions, open_at: u32, close_at: u32) void {
        assert(open_at < close_at);
        assert(elisions.count <= elided_line_max);

        if (elisions.count + 2 > elided_line_max) return;

        elisions.positions[elisions.count] = open_at;

        elisions.positions[elisions.count + 1] = close_at;
        elisions.count += 2;
    }
};

const PendingWord = struct {
    position: u32,
    priority: u8,
};

fn pragma_at_order(offset: u32, held: PragmaAt) std.math.Order {
    assert(held.span.length > 0);
    assert(held.span.end() > held.span.offset);

    return std.math.order(offset, held.span.offset);
}

fn complicated_kind(kind: Kind) bool {
    assert(kind.is_token());

    const result = switch (kind) {
        .and_keyword,
        .colon_equal,
        .dot,
        .else_keyword,
        .equal_equal,
        .greater,
        .greater_equal,
        .if_keyword,
        .lambda_keyword,
        .less,
        .less_equal,
        .not_equal,
        .not_keyword,
        .or_keyword,
        => true,
        else => false,
    };

    if (result) assert(kind.is_token());
    if (result) assert(!ends_operand(kind));

    return result;
}

fn pushed_parts(arena: *Buffer, parts: []const []const u8) error{Overflow}!void {
    assert(parts.len > 0);

    const offset = arena.count();

    for (parts) |bytes| try arena.push(bytes);

    assert(arena.count() >= offset);
}

const Edges = @import("python/literal.zig").Edges;
const ascii_whitespace = @import("../text/scan.zig").ascii_whitespace;
const trim_ascii = @import("../text/scan.zig").trim_ascii;

pub const Targets = enum {
    iterated,
    listed,
    none,
};

const OmitsSplit = struct {
    count: u32,
    found: u8,
};

const WrapsContents = struct {
    commented: bool,
    held: bool,
};

fn elided_stops(kind: Kind, prior: ?Kind, depth: u32, targets: Targets, headed: bool) bool {
    assert(!is_open(kind));
    assert(!is_close(kind));

    if (kind == .comment) return true;
    if (depth > 0) return false;
    if (prior) |held| assert(held.is_token());

    const operand = if (prior) |held| ends_operand(held) else false;
    const unpacked = kind == .star or kind == .star_star;
    if (unpacked) return !operand and targets != .iterated;

    return switch (kind) {
        .for_keyword, .yield_keyword => true,
        .colon_equal => !headed,
        .comma => targets == .none,
        else => false,
    };
}

pub fn wrap_end_stops(head: ?Kind, kind: Kind, clause: bool, words: u32) bool {
    if (head) |known| assert(known.is_token());
    assert(kind != .newline);

    if (kind == .colon) return true;
    if (kind == .comment) return words > 1 or !inlines_comment(head);
    if (is_augmented(kind)) return true;

    const held = head orelse return false;

    return switch (held) {
        .assert_keyword => kind == .comma,
        .colon, .lambda_keyword => kind == .comma or clause or is_close(kind),
        .for_keyword => kind == .in_keyword,
        else => false,
    };
}

fn inlines_comment(head: ?Kind) bool {
    if (head) |held| assert(held.is_token());

    const held = head orelse return true;

    assert(held.is_token());

    if (is_augmented(held)) return true;

    return switch (held) {
        .colon, .equal, .return_keyword, .yield_keyword => true,
        else => false,
    };
}

pub fn is_string_start(kind: Kind) bool {
    assert(kind.is_token());

    const result = switch (kind) {
        .f_string_start, .string_bytes, .string_plain => true,
        else => false,
    };

    if (result) assert(kind.is_token());
    if (result) assert(!is_open(kind));

    return result;
}

pub const Frame = struct {
    annotated: bool,
    call: bool,
    commas: bool,
    commented: bool,
    complex: bool,
    group_count: u32,
    hollow: bool,
    hugged: bool,
    kind: Kind,
    level_count: u32,
    levels: [element_depth_max]u8,
    magic: bool,
    magic_source: bool,
    owes: bool,
    priority: u8,
    sole: bool,
    splits: Splits,
    trailed: bool,

    pub fn new() Frame {
        const frame: Frame = .{
            .annotated = false,
            .call = false,
            .commas = false,
            .commented = false,
            .complex = false,
            .group_count = 0,
            .hollow = false,
            .hugged = false,
            .kind = .paren_open,
            .level_count = 0,
            .levels = @splat(0),
            .magic = false,
            .magic_source = false,
            .owes = false,
            .priority = 0,
            .sole = false,
            .splits = .new(),
            .trailed = false,
        };

        assert(is_open(frame.kind));
        assert(frame.level_count <= element_depth_max);

        return frame;
    }
};

pub const Splits = struct {
    bodied: bool,
    comprehended: bool,
    displayed: bool,
    lambda: bool,
    targeting: bool,

    pub fn new() Splits {
        const splits: Splits = .{
            .bodied = false,
            .comprehended = false,
            .displayed = false,
            .lambda = false,
            .targeting = false,
        };

        assert(!splits.comprehended);
        assert(!splits.targeting);

        return splits;
    }

    pub fn step(splits: *Splits, kind: Kind, previous: ?Kind) u8 {
        assert(kind.is_token());
        if (previous) |held| assert(held.is_token());

        defer if (kind == .colon) assert(!splits.lambda);

        if (splits.bodied) {
            const ends = kind == .comma or kind == .for_keyword or kind == .async_keyword;
            if (!ends) return 0;

            splits.bodied = false;
        }

        switch (kind) {
            .lambda_keyword => {
                splits.lambda = true;

                return 0;
            },
            .colon => {
                splits.bodied = splits.lambda;
                splits.lambda = false;

                return 0;
            },
            .async_keyword => {
                const operand = if (previous) |held| ends_operand(held) else false;

                if (operand) {
                    splits.comprehended = true;
                    splits.targeting = true;

                    return priority_comprehension;
                }
            },
            .for_keyword => {
                splits.comprehended = true;
                splits.targeting = true;

                if (previous == .async_keyword) return 0;
                return priority_comprehension;
            },
            .in_keyword => {
                if (splits.targeting) {
                    splits.targeting = false;

                    return 0;
                }
            },
            .comma => {
                if (splits.lambda) return 0;
                if (splits.targeting) return 0;
                return priority_comma;
            },
            .if_keyword => {
                if (splits.comprehended) return priority_comprehension;
                return priority_ternary;
            },
            .bracket_open => splits.displayed = if (previous) |held| !ends_operand(held) else true,
            .dot => {
                const subscripted = previous == .bracket_close and splits.displayed;
                if (subscripted) return 0;
            },
            else => {},
        }

        return kind_parted(kind, previous);
    }
};

const Literals = struct {
    comma: u32,
    continuation: u32,
    gap: u32,
    spacer: u32,
};

const Parentheses = struct {
    open: u32,
    head: u32,
    close: u32,
};

pub const bracket_depth_max: u32 = 64;
const elided_line_max: u32 = bracket_depth_max * 2;
const element_depth_max: u32 = 8;
pub const format_nest_max: u32 = 8;
const comma = ",";
const continuation = " \\";
const gap = "  ";
pub const paren_close = ")";
pub const paren_head = "(";
pub const paren_open = " (";
const spacer = " ";
pub const priority_comprehension: u8 = 20;
const priority_comma: u8 = 18;
const priority_ternary: u8 = 16;
pub const priority_logic: u8 = 14;
const priority_string: u8 = 12;
pub const priority_comparator: u8 = 10;
const priority_power: u8 = 2;
pub const priority_dot: u8 = 1;
const literal_count_max: u32 = 7;
const emitter_bytes_max: u32 = 1 << 12;

comptime {
    assert(element_depth_max <= bracket_depth_max);
    assert(format_nest_max <= bracket_depth_max);
    assert(priority_comprehension > priority_comma);
    assert(priority_comma > priority_ternary);
    assert(priority_ternary > priority_logic);
    assert(priority_logic > priority_string);
    assert(priority_string > priority_comparator);
    assert(priority_comparator > 9);
    assert(priority_dot < priority_power);
    assert(priority_power < 4);
    assert(@sizeOf(Emitter) <= emitter_bytes_max);
}

fn prefixes(kind: Kind) bool {
    assert(kind.is_token());

    const result = switch (kind) {
        .await_keyword, .minus, .not_keyword, .plus, .tilde, .yield_keyword => true,
        else => false,
    };

    if (result) assert(kind.is_token());
    if (result) assert(!ends_operand(kind));

    return result;
}

pub fn kind_parted(kind: Kind, previous: ?Kind) u8 {
    assert(kind.is_token());
    if (previous) |held| assert(held.is_token());

    const held = previous orelse return 0;
    const binary: u8 = @intFromBool(ends_operand(held));

    const priority: u8 = switch (kind) {
        .ampersand => binary * 7,
        .and_keyword, .or_keyword => priority_logic,
        .at, .percent, .slash, .slash_slash, .star => binary * 4,
        .bar => binary * 9,
        .caret => binary * 8,
        .dot => @as(u8, @intFromBool(is_close(held) and held != .brace_close)) * priority_dot,
        .else_keyword => priority_ternary,
        .equal_equal,
        .greater,
        .greater_equal,
        .is_keyword,
        .less,
        .less_equal,
        .not_equal,
        => priority_comparator,
        .in_keyword => @as(u8, @intFromBool(held != .not_keyword)) * priority_comparator,
        .f_string_start, .string_bytes, .string_plain => @as(u8, @intFromBool(kind_joined(held))) *
            priority_string,
        .greater_greater, .less_less => binary * 6,
        .minus, .plus => binary * 5,
        .not_keyword => @as(u8, @intFromBool(held != .is_keyword)) * binary * priority_comparator,
        .star_star => binary * priority_power,
        else => 0,
    };

    assert(priority <= priority_ternary);
    if (priority > 0) assert(kind.is_token());

    return priority;
}

fn emitting(input: *const Input, formatter: *Formatter) Emitter {
    assert(input.tokens.len == input.raw.len);
    assert(formatter.statements[0].kind == .none);

    return .{
        .after = false,
        .arena = &formatter.arena,
        .at_lambda = null,
        .at_previous = null,
        .blocks = @splat(false),
        .closed = false,
        .columns = @splat(0),
        .concat_at = null,
        .concat_span = .empty,
        .continued = false,
        .depth = 0,
        .document = &formatter.document,
        .documented = false,
        .documented_past = false,
        .elided = @splat(0),
        .elided_line = .empty,
        .elisions = 0,
        .formatted = .idle,
        .frames = @splat(.new()),
        .functions = @splat(false),
        .hug_break = null,
        .hug_depth = 0,
        .hug_end = null,
        .hugged = false,
        .indent = 0,
        .indent_width = input.options.indent_width,
        .@"inline" = 0,
        .line_depth = 0,
        .line_first = null,
        .line_first_at = null,
        .line_width = input.options.line_width,
        .literals = formatter.literals(),
        .lowered = 0,
        .magic_trailing_comma = input.magic_trailing_comma,
        .opened = false,
        .parentheses = formatter.parentheses(),
        .pending_break = false,
        .pending_word = null,
        .powers = .empty,
        .pragmas = input.pragmas,
        .previous = null,
        .quote = input.quote,
        .raw = input.raw,
        .skip = null,
        .source = input.source,
        .starting = false,
        .statements = &formatter.statements,
        .stub = input.stub,
        .stubbed = false,
        .stubbed_function = false,
        .suppress_space = false,
        .tokens = input.tokens,
        .until = 0,
        .walrus = false,
        .wrap = null,
        .wrap_depth = 0,
        .wrap_headed = false,
        .wrap_outer = .new(),
        .wrap_sole = false,
        .wrap_tuple = false,
        .wrapper = .new(),
    };
}

pub fn ends_operand(kind: Kind) bool {
    assert(kind.is_token());

    const result = switch (kind) {
        .brace_close,
        .bracket_close,
        .ellipsis,
        .f_string_end,
        .false_keyword,
        .identifier,
        .none_keyword,
        .number_binary,
        .number_complex,
        .number_float,
        .number_hexadecimal,
        .number_integer,
        .number_octal,
        .paren_close,
        .string_bytes,
        .string_format,
        .string_plain,
        .true_keyword,
        => true,
        else => false,
    };

    if (result) assert(kind.is_token());
    if (result) assert(!kind.is_trivia());

    return result;
}

fn is_binary(kind: Kind) bool {
    assert(kind.is_token());

    const result = switch (kind) {
        .ampersand,
        .and_keyword,
        .bar,
        .caret,
        .greater_greater,
        .in_keyword,
        .is_keyword,
        .less_less,
        .minus,
        .or_keyword,
        .percent,
        .plus,
        .slash,
        .slash_slash,
        .star,
        .star_star,
        => true,
        else => false,
    };

    if (result) assert(!ends_operand(kind));
    if (result) assert(!is_open(kind));

    return result;
}

pub fn is_unary(kind: Kind) bool {
    assert(kind.is_token());

    const result = switch (kind) {
        .minus, .not_keyword, .plus, .tilde => true,
        else => false,
    };

    if (result) assert(prefixes(kind));
    if (result) assert(!ends_operand(kind));

    return result;
}

pub fn is_augmented(kind: Kind) bool {
    assert(kind.is_token());

    const result = switch (kind) {
        .ampersand_equal,
        .at_equal,
        .bar_equal,
        .caret_equal,
        .greater_greater_equal,
        .less_less_equal,
        .minus_equal,
        .percent_equal,
        .plus_equal,
        .slash_equal,
        .slash_slash_equal,
        .star_equal,
        .star_star_equal,
        => true,
        else => false,
    };

    if (result) assert(elides_after(kind));
    if (result) assert(!ends_operand(kind));

    return result;
}

fn stops_chain(kind: Kind) bool {
    if (is_augmented(kind)) return true;

    const result = switch (kind) {
        .arrow,
        .as_keyword,
        .assert_keyword,
        .async_keyword,
        .await_keyword,
        .colon,
        .colon_equal,
        .comma,
        .del_keyword,
        .elif_keyword,
        .else_keyword,
        .equal,
        .except_keyword,
        .for_keyword,
        .from_keyword,
        .if_keyword,
        .import_keyword,
        .lambda_keyword,
        .newline,
        .raise_keyword,
        .return_keyword,
        .semicolon,
        .while_keyword,
        .with_keyword,
        .yield_keyword,
        => true,
        else => false,
    };

    if (result) assert(kind.is_token());
    if (result) assert(!ends_operand(kind));

    return result;
}

fn operates(kind: Kind) bool {
    assert(kind.is_token());

    const result = switch (kind) {
        .ampersand,
        .and_keyword,
        .at,
        .bar,
        .caret,
        .equal_equal,
        .greater,
        .greater_equal,
        .greater_greater,
        .in_keyword,
        .is_keyword,
        .less,
        .less_equal,
        .less_less,
        .minus,
        .not_equal,
        .or_keyword,
        .percent,
        .plus,
        .slash,
        .slash_slash,
        .star,
        .star_star,
        => true,
        else => false,
    };

    if (result) assert(kind.is_token());
    if (result) assert(!ends_operand(kind));

    return result;
}

pub fn is_close(kind: Kind) bool {
    assert(kind.is_token());

    const result = switch (kind) {
        .brace_close, .bracket_close, .paren_close => true,
        else => false,
    };

    if (result) assert(ends_operand(kind));
    if (result) assert(!is_open(kind));

    return result;
}

pub fn opens_suite(kind: ?Kind) bool {
    if (kind) |held| assert(held.is_token());

    const held = kind orelse return false;

    const result = switch (held) {
        .async_keyword,
        .class_keyword,
        .def_keyword,
        .elif_keyword,
        .else_keyword,
        .except_keyword,
        .finally_keyword,
        .for_keyword,
        .if_keyword,
        .try_keyword,
        .while_keyword,
        .with_keyword,
        => true,
        else => false,
    };

    if (result) assert(std.mem.endsWith(u8, @tagName(held), "_keyword"));
    if (result) assert(!ends_operand(held));

    return result;
}

pub fn signed(kind: Kind) bool {
    assert(kind.is_token());

    const result = switch (kind) {
        .minus, .plus, .star, .star_star, .tilde => true,
        else => false,
    };

    if (result) assert(kind.is_token());
    if (result) assert(!ends_operand(kind));

    return result;
}

pub fn worded(kind: Kind) bool {
    assert(kind.is_token());

    const result = switch (kind) {
        .and_keyword,
        .as_keyword,
        .await_keyword,
        .else_keyword,
        .for_keyword,
        .if_keyword,
        .in_keyword,
        .is_keyword,
        .lambda_keyword,
        .not_keyword,
        .or_keyword,
        => true,
        else => false,
    };

    if (result) assert(std.mem.endsWith(u8, @tagName(kind), "_keyword"));
    if (result) assert(!ends_operand(kind));

    return result;
}

pub fn blanked(previous: Kind, current: Kind) bool {
    assert(previous.is_token());
    assert(current.is_token());

    if (is_open(previous)) return false;
    if (is_close(current)) return false;
    if (previous == .f_string_start) return false;
    if (previous == .f_string_middle) return false;
    if (current == .f_string_end) return false;
    if (current == .f_string_middle) return false;
    if (current == .comma) return false;
    if (current == .dot) return false;
    if (current == .semicolon) return false;
    if (previous == .dot) return false;
    if (current == .bracket_open) return !ends_operand(previous);
    if (current == .paren_open) return !ends_operand(previous);
    return true;
}

fn kind_joined(kind: Kind) bool {
    assert(kind.is_token());

    const result = switch (kind) {
        .f_string_end, .string_bytes, .string_plain => true,
        else => false,
    };

    if (result) assert(ends_operand(kind));
    if (result) assert(kind.is_token());

    return result;
}

pub fn joined_head(kind: Kind, text: []const u8) ?u32 {
    assert(text.len <= std.math.maxInt(u32));
    assert(kind.is_token());

    const head: ?u32 = switch (kind) {
        .f_string_start => @intCast(text.len),
        .string_bytes, .string_plain => if (body_edges(text)) |edges| edges.head else null,
        else => null,
    };

    if (head) |held| assert(held <= text.len);

    return head;
}

pub fn joined_tail(kind: Kind, text: []const u8) u32 {
    assert(text.len <= std.math.maxInt(u32));
    assert(kind.is_token());

    const tail: u32 = switch (kind) {
        .f_string_end => @intCast(text.len),
        .string_bytes, .string_plain => if (body_edges(text)) |edges|
            @as(u32, @intCast(text.len)) - edges.tail
        else
            0,
        else => 0,
    };

    assert(tail <= text.len);

    return tail;
}

pub fn ends_line(kind: Kind) bool {
    assert(kind.is_token());

    const result = kind == .newline or kind == .semicolon;

    if (result) assert(kind.is_token());
    if (result) assert(!ends_operand(kind));

    return result;
}

pub fn is_layout(kind: Kind) bool {
    assert(kind.is_token());

    const result = switch (kind) {
        .dedent, .indent, .newline => true,
        else => false,
    };

    if (result) assert(kind.is_token());
    if (result) assert(!ends_operand(kind));

    return result;
}

pub fn is_number(kind: Kind) bool {
    assert(kind.is_token());

    const result = switch (kind) {
        .number_binary,
        .number_complex,
        .number_float,
        .number_hexadecimal,
        .number_integer,
        .number_octal,
        => true,
        else => false,
    };

    if (result) assert(ends_operand(kind));
    if (result) assert(std.mem.startsWith(u8, @tagName(kind), "number_"));

    return result;
}

pub fn is_open(kind: Kind) bool {
    assert(kind.is_token());

    const result = switch (kind) {
        .brace_open, .bracket_open, .paren_open => true,
        else => false,
    };

    if (result) assert(kind.is_token());
    if (result) assert(!ends_operand(kind));

    return result;
}

fn opened_by(close: Kind) Kind {
    assert(close.is_token());

    const open: Kind = switch (close) {
        .brace_close => .brace_open,
        .bracket_close => .bracket_open,
        else => .paren_open,
    };

    assert(is_open(open));
    if (close == .paren_close) assert(open == .paren_open);

    return open;
}

pub fn elides_after(kind: Kind) bool {
    assert(kind.is_token());

    const result = switch (kind) {
        .ampersand_equal,
        .arrow,
        .assert_keyword,
        .at_equal,
        .await_keyword,
        .bar_equal,
        .caret_equal,
        .del_keyword,
        .elif_keyword,
        .equal,
        .greater_greater_equal,
        .if_keyword,
        .less_less_equal,
        .minus_equal,
        .percent_equal,
        .plus_equal,
        .return_keyword,
        .slash_equal,
        .slash_slash_equal,
        .star_equal,
        .star_star_equal,
        .while_keyword,
        .with_keyword,
        => true,
        else => false,
    };

    if (result) assert(kind.is_token());
    if (result) assert(!ends_operand(kind));

    return result;
}

fn balanced(raw: []const Kind) bool {
    assert(raw.len <= std.math.maxInt(u32));

    var depth: u32 = 0;
    var stack: [bracket_depth_max]Kind = @splat(.paren_open);

    for (raw) |kind| {
        if (is_open(kind)) {
            if (depth == bracket_depth_max) return false;

            stack[depth] = kind;
            depth += 1;

            continue;
        }

        if (!is_close(kind)) continue;
        if (depth == 0) return false;
        if (stack[depth - 1] != opened_by(kind)) return false;

        depth -= 1;
    }

    assert(depth <= bracket_depth_max);
    if (raw.len == 0) assert(depth == 0);

    return depth == 0;
}

fn broken(raw: []const Kind, tree: *const Tree) bool {
    assert(raw.len <= std.math.maxInt(u32));
    assert(tree.count() <= tree.nodes.capacity());

    if (std.mem.findScalar(Kind, raw, .error_token) != null) return true;
    if (!balanced(raw)) return true;

    for (tree.slice()) |node| {
        if (node.kind == .error_node) return true;
    }

    return false;
}

pub fn blank_lines(source: []const u8, from: u32, to: u32) u32 {
    assert(from <= to);
    assert(to <= source.len);

    const breaks: u32 = @intCast(std.mem.count(u8, source[from..to], "\n"));

    assert(breaks <= to - from);

    return breaks;
}

fn pragmas_sorted(pragmas: []const PragmaAt) bool {
    assert(pragmas.len <= std.math.maxInt(u32));

    if (pragmas.len < 2) return true;

    for (pragmas[0 .. pragmas.len - 1], pragmas[1..]) |before, after| {
        if (before.span.offset > after.span.offset) return false;
    }

    return true;
}

fn format_refused(input: *const Input) bool {
    assert(input.tokens.len == input.raw.len);
    assert(input.source.len <= std.math.maxInt(u32));

    if (input.outcome != .complete) return true;
    if (input.tree.diagnostic_slice().len > 0) return true;
    if (target.invalid(input.tree)) return true;
    return broken(input.raw, input.tree);
}

const Parsed = struct {
    events: *EventsType(Kind),
    parser: *Parser,
    raw: ArrayType(Kind),
    tokens: Tokens,
    tree: Tree,

    fn init(parsed: *Parsed, source: []const u8) !void {
        const gpa = std.testing.allocator;

        assert(source.len > 0);
        assert(source.len <= 1 << 8);

        parsed.tokens = try .init(gpa, 1 << 8);
        errdefer parsed.tokens.deinit(gpa);

        parsed.raw = try .init(gpa, 1 << 8);
        errdefer parsed.raw.deinit(gpa);

        parsed.events = try gpa.create(EventsType(Kind));
        errdefer gpa.destroy(parsed.events);

        try parsed.events.init(gpa, 1 << 10);
        errdefer parsed.events.deinit(gpa);

        parsed.tree = try .init(gpa, 1 << 8, 1 << 4);
        errdefer parsed.tree.deinit(gpa);

        parsed.parser = try gpa.create(Parser);
        errdefer gpa.destroy(parsed.parser);

        try lex(.of(.python), source, &parsed.tokens);
        try raw_of(Kind, parsed.tokens.slice(), &parsed.raw);

        const tokens = parsed.tokens.slice();
        const raw = parsed.raw.const_slice();
        const built = parsed.parser.build(source, tokens, raw, parsed.events, &parsed.tree);

        assert(built == .complete);
        assert(parsed.tree.count() > 0);
    }

    fn deinit(parsed: *Parsed) void {
        const gpa = std.testing.allocator;

        assert(parsed.tree.count() > 0);
        assert(parsed.tokens.count() == parsed.raw.count());

        gpa.destroy(parsed.parser);
        parsed.tree.deinit(gpa);
        parsed.events.deinit(gpa);
        gpa.destroy(parsed.events);
        parsed.raw.deinit(gpa);
        parsed.tokens.deinit(gpa);
        parsed.* = undefined;
    }
};

test "a splits step ranks each separator the way the line splits at it" {
    var splits: Splits = .new();

    try std.testing.expectEqual(priority_comma, splits.step(.comma, .identifier));
    try std.testing.expectEqual(@as(u8, 0), splits.step(.lambda_keyword, .comma));
    try std.testing.expectEqual(@as(u8, 0), splits.step(.comma, .identifier));
    try std.testing.expectEqual(@as(u8, 0), splits.step(.colon, .identifier));
    try std.testing.expect(!splits.lambda);
    try std.testing.expect(splits.bodied);
    try std.testing.expectEqual(@as(u8, 0), splits.step(.if_keyword, .identifier));
    try std.testing.expectEqual(priority_comma, splits.step(.comma, .identifier));
    try std.testing.expect(!splits.bodied);
    try std.testing.expectEqual(priority_ternary, splits.step(.if_keyword, .identifier));
    try std.testing.expectEqual(priority_comparator, splits.step(.in_keyword, .identifier));

    splits = .new();

    try std.testing.expectEqual(priority_comprehension, splits.step(.for_keyword, .identifier));
    try std.testing.expectEqual(@as(u8, 0), splits.step(.comma, .identifier));
    try std.testing.expectEqual(@as(u8, 0), splits.step(.in_keyword, .identifier));
    try std.testing.expect(!splits.targeting);
    try std.testing.expectEqual(priority_comprehension, splits.step(.if_keyword, .identifier));

    splits = .new();

    try std.testing.expectEqual(priority_comprehension, splits.step(.async_keyword, .identifier));
    try std.testing.expectEqual(@as(u8, 0), splits.step(.for_keyword, .async_keyword));

    splits = .new();

    try std.testing.expectEqual(@as(u8, 0), splits.step(.async_keyword, null));
    try std.testing.expect(!splits.comprehended);
}

test "a parted operator takes the priority its precedence gives it" {
    const cases = [_]struct { Kind, ?Kind, u8 }{
        .{ .plus, null, 0 },
        .{ .plus, .identifier, 5 },
        .{ .plus, .comma, 0 },
        .{ .star, .number_integer, 4 },
        .{ .bar, .paren_close, 9 },
        .{ .caret, .identifier, 8 },
        .{ .ampersand, .identifier, 7 },
        .{ .less_less, .identifier, 6 },
        .{ .and_keyword, .comma, priority_logic },
        .{ .dot, .paren_close, priority_dot },
        .{ .dot, .identifier, 0 },
        .{ .else_keyword, .identifier, priority_ternary },
        .{ .equal_equal, .comma, priority_comparator },
        .{ .in_keyword, .not_keyword, 0 },
        .{ .in_keyword, .identifier, priority_comparator },
        .{ .string_plain, .string_plain, priority_string },
        .{ .f_string_start, .f_string_end, priority_string },
        .{ .string_plain, .identifier, 0 },
        .{ .not_keyword, .identifier, priority_comparator },
        .{ .not_keyword, .is_keyword, 0 },
        .{ .star_star, .identifier, priority_power },
        .{ .colon, .identifier, 0 },
    };

    for (cases) |case| {
        try std.testing.expectEqual(case[2], kind_parted(case[0], case[1]));
    }
}

test "a blank sits between words and never inside brackets" {
    try std.testing.expect(blanked(.identifier, .identifier));
    try std.testing.expect(!blanked(.paren_open, .identifier));
    try std.testing.expect(!blanked(.identifier, .paren_close));
    try std.testing.expect(!blanked(.f_string_start, .identifier));
    try std.testing.expect(!blanked(.identifier, .f_string_middle));
    try std.testing.expect(!blanked(.identifier, .comma));
    try std.testing.expect(!blanked(.dot, .identifier));
    try std.testing.expect(!blanked(.identifier, .paren_open));
    try std.testing.expect(blanked(.comma, .paren_open));
    try std.testing.expect(!blanked(.dot, .paren_open));
}

test "a joined string reads its head and its tail" {
    try std.testing.expectEqual(@as(?u32, 2), joined_head(.f_string_start, "f'"));
    try std.testing.expectEqual(@as(?u32, 1), joined_head(.string_plain, "'abc'"));
    try std.testing.expectEqual(@as(?u32, 4), joined_head(.string_bytes, "b'''x'''"));
    try std.testing.expectEqual(@as(?u32, null), joined_head(.identifier, "x"));
    try std.testing.expectEqual(@as(?u32, null), joined_head(.string_plain, "abc"));
    try std.testing.expectEqual(@as(u32, 1), joined_tail(.f_string_end, "'"));
    try std.testing.expectEqual(@as(u32, 1), joined_tail(.string_plain, "'abc'"));
    try std.testing.expectEqual(@as(u32, 3), joined_tail(.string_bytes, "b'''x'''"));
    try std.testing.expectEqual(@as(u32, 0), joined_tail(.identifier, "x"));
}

test "a bracket run balances only when every close meets its open" {
    const deep: [bracket_depth_max + 1]Kind = @splat(.paren_open);
    const opens: [bracket_depth_max]Kind = @splat(.paren_open);
    const closes: [bracket_depth_max]Kind = @splat(.paren_close);
    const full = opens ++ closes;
    const nested = [_]Kind{ .paren_open, .bracket_open, .bracket_close, .paren_close };

    try std.testing.expect(balanced(&nested));
    try std.testing.expect(!balanced(&.{ .paren_open, .bracket_close }));
    try std.testing.expect(!balanced(&.{.paren_close}));
    try std.testing.expect(!balanced(&.{.brace_open}));
    try std.testing.expect(!balanced(&deep));
    try std.testing.expect(balanced(&full));
    try std.testing.expect(balanced(&.{}));
}

test "a broken source is a stray token, a lone bracket or an error node" {
    var parsed: Parsed = undefined;

    try parsed.init("x = (1)\n");
    defer parsed.deinit();

    try std.testing.expect(!broken(parsed.raw.const_slice(), &parsed.tree));
    try std.testing.expect(broken(&.{ .identifier, .error_token }, &parsed.tree));
    try std.testing.expect(broken(&.{.paren_open}, &parsed.tree));

    var tree: Tree = try .init(std.testing.allocator, 4, 4);
    defer tree.deinit(std.testing.allocator);

    try tree.push(.error_node, null, 0);
    tree.set_token_end(0, 0);

    try std.testing.expect(broken(&.{.identifier}, &tree));
}

test "statements of a range are the module children it touches" {
    const source = "x = 1\ny = 2  # note\nz = 3\n";
    var parsed: Parsed = undefined;

    try parsed.init(source);
    defer parsed.deinit();

    const tree = &parsed.tree;
    const tokens = parsed.tokens.slice();
    const middle = statements_of(tree, tokens, .{ .offset = 7, .length = 1 }).?;
    const head = statements_of(tree, tokens, .{ .offset = 0, .length = 12 }).?;

    try std.testing.expectEqual(middle.first, middle.last);
    try std.testing.expect(head.first < head.last);
    try std.testing.expectEqual(head.last, middle.first);

    const middle_span = source_span(source, tree, tokens, middle);
    const head_span = source_span(source, tree, tokens, head);

    try std.testing.expectEqualStrings("y = 2  # note\n", middle_span.text(source));
    try std.testing.expectEqualStrings("x = 1\ny = 2  # note\n", head_span.text(source));
    try std.testing.expectEqual(null, statements_of(tree, tokens, .{ .offset = 6, .length = 0 }));
    try std.testing.expectEqual(null, statements_of(tree, tokens, .{ .offset = 99, .length = 1 }));

    var empty: Tree = try .init(std.testing.allocator, 1, 1);
    defer empty.deinit(std.testing.allocator);

    try std.testing.expectEqual(null, statements_of(&empty, tokens, .{ .offset = 0, .length = 1 }));
}

test "the word helpers find the lines that hold the counted words" {
    const source = "x = 1\ny = 2\nz = 3\n";
    var lexed: Tokens = try .init(std.testing.allocator, 1 << 6);
    defer lexed.deinit(std.testing.allocator);

    try lex(.of(.python), source, &lexed);

    const tokens = lexed.slice();

    try std.testing.expectEqual(@as(u32, 2), words_before(tokens, 4));
    try std.testing.expectEqual(@as(u32, 6), words_before(tokens, 99));
    try std.testing.expectEqual(Run{ .first = 4, .last = 6 }, word_positions(tokens, 2, 4).?);
    try std.testing.expectEqual(null, word_positions(tokens, 2, 2));
    try std.testing.expectEqual(null, word_positions(tokens, 0, 9));
    try std.testing.expectEqual(@as(u32, 4), line_start_of(tokens, 6));
    try std.testing.expectEqual(@as(u32, 7), line_end_of(tokens, 4));
    try std.testing.expectEqualStrings("y = 2\n", word_span(tokens, 2, 4).?.text(source));
    try std.testing.expectEqual(null, word_span(tokens, 5, 9));
}

test "a blank line count reads the line feeds between two offsets" {
    try std.testing.expectEqual(@as(u32, 3), blank_lines("a\n\nb\n", 0, 5));
    try std.testing.expectEqual(@as(u32, 2), blank_lines("a\n\nb\n", 1, 3));
    try std.testing.expectEqual(@as(u32, 0), blank_lines("a\n\nb\n", 0, 0));
}

test "a range span covers the lines it names" {
    const bytes = "x = 1\ny = 2\nz = 3\n";
    const middle = range_span(bytes, .{ .first = 1, .last = 1 }).?;
    const whole = range_span(bytes, .{ .first = 0, .last = 2 }).?;
    const tail = range_span(bytes, .{ .first = 2, .last = 9 }).?;
    const unbroken = range_span("abc", .{ .first = 0, .last = 0 }).?;

    try std.testing.expectEqualStrings("y = 2\n", middle.text(bytes));
    try std.testing.expectEqualStrings(bytes, whole.text(bytes));
    try std.testing.expectEqualStrings("z = 3\n", tail.text(bytes));
    try std.testing.expectEqual(Span{ .offset = 0, .length = 3 }, unbroken);
    try std.testing.expectEqual(null, range_span(bytes, .{ .first = 5, .last = 6 }));
}

test "a formatter registers the six literals it emits" {
    var formatter: Formatter = try .init(std.testing.allocator, 16, 64);
    defer formatter.deinit(std.testing.allocator);

    const document = &formatter.document;

    try std.testing.expectEqualStrings(",", document.literal_of(formatter.comma));
    try std.testing.expectEqualStrings("  ", document.literal_of(formatter.gap));
    try std.testing.expectEqualStrings(" (", document.literal_of(formatter.open));
    try std.testing.expectEqualStrings("(", document.literal_of(formatter.head));
    try std.testing.expectEqualStrings(" ", document.literal_of(formatter.spacer));
    try std.testing.expectEqualStrings(" \\", document.literal_of(formatter.continuation));
    try std.testing.expectEqualStrings(")", document.literal_of(formatter.close));
    try std.testing.expect(Input.defaults.magic_trailing_comma);
    try std.testing.expectEqual(QuotePreference.double, Input.defaults.quote);
    try std.testing.expectEqual(LineEnding.line_feed, Input.defaults.line_ending);
}

test "a reline writes every line break in the wanted ending" {
    const gpa = std.testing.allocator;
    var formatter: Formatter = try .init(gpa, 16, 64);
    defer formatter.deinit(gpa);

    var out: Buffer = try .init(gpa, 64);
    defer out.deinit(gpa);

    try out.push("a\r\nb\rc\n");
    try formatter.reline(.line_feed, &out);
    try std.testing.expectEqualStrings("a\nb\nc\n", out.const_slice());

    out.clear();

    try out.push("a\nb\n");
    try formatter.reline(.carriage_return_line_feed, &out);
    try std.testing.expectEqualStrings("a\r\nb\r\n", out.const_slice());

    var narrow: Buffer = try .init(gpa, 4);
    defer narrow.deinit(gpa);

    try narrow.push("a\nb\n");
    const widened = formatter.reline(.carriage_return_line_feed, &narrow);

    try std.testing.expectError(error.Overflow, widened);

    var arena_narrow: Formatter = try .init(gpa, 16, 2);
    defer arena_narrow.deinit(gpa);

    narrow.clear();

    try narrow.push("a\rb\r");
    try std.testing.expectError(error.Overflow, arena_narrow.reline(.line_feed, &narrow));
}

test "the token families hold the kinds the formatter groups" {
    try std.testing.expect(prefixes(.yield_keyword));
    try std.testing.expect(!prefixes(.star));
    try std.testing.expect(is_binary(.star_star));
    try std.testing.expect(!is_binary(.tilde));
    try std.testing.expect(is_unary(.tilde));
    try std.testing.expect(!is_unary(.star));
    try std.testing.expect(opens_suite(.with_keyword));
    try std.testing.expect(!opens_suite(.return_keyword));
    try std.testing.expect(!opens_suite(null));
    try std.testing.expect(signed(.star));
    try std.testing.expect(!signed(.not_keyword));
    try std.testing.expect(worded(.lambda_keyword));
    try std.testing.expect(!worded(.identifier));
    try std.testing.expect(is_layout(.dedent));
    try std.testing.expect(!is_layout(.comment));
    try std.testing.expect(is_number(.number_octal));
    try std.testing.expect(!is_number(.string_plain));
    try std.testing.expect(elides_after(.return_keyword));
    try std.testing.expect(!elides_after(.identifier));
    try std.testing.expect(kind_joined(.f_string_end));
    try std.testing.expect(!kind_joined(.f_string_start));
    try std.testing.expectEqual(Kind.brace_open, opened_by(.brace_close));
    try std.testing.expectEqual(Kind.bracket_open, opened_by(.bracket_close));
    try std.testing.expectEqual(Kind.paren_open, opened_by(.paren_close));
    try std.testing.expect(is_word(.number));
    try std.testing.expect(!is_word(.comment));
    try std.testing.expect(is_line_edge(.block_start));
    try std.testing.expect(!is_line_edge(.string));
}

test "pragmas out of offset order fail the order check" {
    const first: PragmaAt = .{ .kind = .format_off, .line = 0, .span = .{
        .offset = 0,
        .length = 4,
    } };

    const second: PragmaAt = .{ .kind = .format_on, .line = 2, .span = .{
        .offset = 9,
        .length = 4,
    } };

    try std.testing.expect(pragmas_sorted(&.{}));
    try std.testing.expect(pragmas_sorted(&.{ first, second }));
    try std.testing.expect(!pragmas_sorted(&.{ second, first }));
}

test "a fresh frame opens a parenthesis with no levels" {
    const frame: Frame = .new();
    const fields: Fields = .none;

    try std.testing.expectEqual(Kind.paren_open, frame.kind);
    try std.testing.expectEqual(@as(u32, 0), frame.level_count);
    try std.testing.expect(!frame.splits.lambda);
    try std.testing.expectEqual(@as(u32, 0), fields.formats);
    try std.testing.expectEqual(@as(?u32, null), fields.nests[0].field.tupled);
    try std.testing.expect(@sizeOf(Emitter) <= emitter_bytes_max);
}

const Index = @import("../text/line_index.zig").LineIndex;
const Pragmas = @import("pragma.zig").Pragmas;

const Formatted = struct {
    events: *EventsType(Kind),
    formatter: Formatter,
    index: Index,
    out: Buffer,
    parser: *Parser,
    pragmas: Pragmas,
    raw: ArrayType(Kind),
    tokens: Tokens,
    tree: Tree,

    fn init(formatted: *Formatted) !void {
        const gpa = std.testing.allocator;

        formatted.formatter = try .init(gpa, 1 << 14, 1 << 16);
        errdefer formatted.formatter.deinit(gpa);

        formatted.index = try .init(gpa, 1 << 12);
        errdefer formatted.index.deinit(gpa);

        formatted.out = try .init(gpa, 1 << 14);
        errdefer formatted.out.deinit(gpa);

        formatted.pragmas = try .init(gpa, 1 << 8);
        errdefer formatted.pragmas.deinit(gpa);

        formatted.raw = try .init(gpa, 1 << 12);
        errdefer formatted.raw.deinit(gpa);

        formatted.tokens = try .init(gpa, 1 << 12);
        errdefer formatted.tokens.deinit(gpa);

        formatted.tree = try .init(gpa, 1 << 12, 1 << 6);
        errdefer formatted.tree.deinit(gpa);

        formatted.events = try gpa.create(EventsType(Kind));
        errdefer gpa.destroy(formatted.events);

        try formatted.events.init(gpa, 1 << 14);
        errdefer formatted.events.deinit(gpa);

        formatted.parser = try gpa.create(Parser);

        assert(formatted.out.empty());
        assert(formatted.tree.count() == 0);
    }

    fn deinit(formatted: *Formatted) void {
        const gpa = std.testing.allocator;

        assert(formatted.tokens.count() == formatted.raw.count());
        assert(formatted.out.count() <= formatted.out.capacity());

        gpa.destroy(formatted.parser);
        formatted.events.deinit(gpa);
        gpa.destroy(formatted.events);
        formatted.tree.deinit(gpa);
        formatted.tokens.deinit(gpa);
        formatted.raw.deinit(gpa);
        formatted.pragmas.deinit(gpa);
        formatted.out.deinit(gpa);
        formatted.index.deinit(gpa);
        formatted.formatter.deinit(gpa);
        formatted.* = undefined;
    }

    fn format(formatted: *Formatted, source: []const u8, scanned: bool) ![]const u8 {
        assert(source.len > 0);
        assert(formatted.out.empty());

        try lex(.of(.python), source, &formatted.tokens);
        try raw_of(Kind, formatted.tokens.slice(), &formatted.raw);

        if (scanned) {
            try formatted.index.build(source);
            try formatted.pragmas.scan(source, formatted.tokens.slice(), &formatted.index);
        }

        const tokens = formatted.tokens.slice();
        const raw = formatted.raw.const_slice();
        const events = formatted.events;
        const outcome = formatted.parser.build(source, tokens, raw, events, &formatted.tree);

        const input: Input = .{
            .line_ending = .line_feed,
            .magic_trailing_comma = true,
            .options = .default,
            .outcome = outcome,
            .pragmas = formatted.pragmas.const_slice(),
            .quote = .double,
            .raw = raw,
            .source = source,
            .stub = false,
            .tokens = tokens,
            .tree = &formatted.tree,
        };

        try formatted.formatter.format(&input, &formatted.out);

        return formatted.out.const_slice();
    }
};

fn expect_formatted(source: []const u8, expected: []const u8) !void {
    assert(source.len > 0);
    assert(expected.len > 0);

    var formatted: Formatted = undefined;

    try formatted.init();
    defer formatted.deinit();

    try std.testing.expectEqualStrings(expected, try formatted.format(source, false));
}

fn expect_pragmatic(source: []const u8, expected: []const u8) !void {
    assert(source.len > 0);
    assert(expected.len > 0);

    var formatted: Formatted = undefined;

    try formatted.init();
    defer formatted.deinit();

    try std.testing.expectEqualStrings(expected, try formatted.format(source, true));
}

test "a region spanning a block is emitted verbatim" {
    const source = "def held(a):\n" ++
        "    # fmt: off\n" ++
        "    if a:\n" ++
        "          b = [1,2,\n" ++
        "     3]\n" ++
        "    # fmt: on\n" ++
        "    c = [1,2]\n";

    const expected = "def held(a):\n" ++
        "    # fmt: off\n" ++
        "    if a:\n" ++
        "          b = [1,2,\n" ++
        "     3]\n" ++
        "    # fmt: on\n" ++
        "    c = [1, 2]\n";

    try expect_pragmatic(source, expected);
}

test "an unbalanced region closes at its dedent" {
    const source = "def held(a):\n" ++
        "    # fmt: off\n" ++
        "    if a:\n" ++
        "          b = [1,2,\n" ++
        "     3]\n" ++
        "\n" ++
        "\n" ++
        "c = [1,2]\n";

    const expected = "def held(a):\n" ++
        "    # fmt: off\n" ++
        "    if a:\n" ++
        "          b = [1,2,\n" ++
        "     3]\n" ++
        "\n" ++
        "\n" ++
        "c = [1, 2]\n";

    try expect_pragmatic(source, expected);
}

test "a statement is spaced the way ruff spaces one" {
    try expect_formatted("x=1\ny  =  2\n", "x = 1\ny = 2\n");
    try expect_formatted("a=b+c*d\n", "a = b + c * d\n");
    try expect_formatted("a=b**c\n", "a = b**c\n");
    try expect_formatted("a=-b\n", "a = -b\n");
    try expect_formatted("a=x.y.z\n", "a = x.y.z\n");
    try expect_formatted("a=x[1:2]\n", "a = x[1:2]\n");
    try expect_formatted("f(a,b=1,*c,**d)\n", "f(a, b=1, *c, **d)\n");
}

test "a definition carries the blank lines ruff gives it" {
    try expect_formatted(
        "import os\ndef f():\n    pass\n",
        "import os\n\n\ndef f():\n    pass\n",
    );

    try expect_formatted(
        "class A:\n\n    def m(self):\n        pass\n",
        "class A:\n    def m(self):\n        pass\n",
    );
}

test "a line over the width breaks inside its brackets" {
    const source = "result = call(argument_one, argument_two, argument_three, " ++
        "argument_four, argument_fivess)\n";

    const expected = "result = call(\n    argument_one, argument_two, argument_three, " ++
        "argument_four, argument_fivess\n)\n";

    try expect_formatted(source, expected);
}

test "a bracket whose body is still too wide splits at its commas" {
    const source = "outcome = call(argument_one, argument_two, argument_three, " ++
        "argument_four, argument_five, argument_six, argument_seven)\n";

    const expected = "outcome = call(\n    argument_one,\n    argument_two,\n    " ++
        "argument_three,\n    argument_four,\n    argument_five,\n    argument_six,\n    " ++
        "argument_seven,\n)\n";

    try expect_formatted(source, expected);
}

test "a magic trailing comma holds its brackets open" {
    try expect_formatted("x = [\n    1,\n    2,\n]\n", "x = [\n    1,\n    2,\n]\n");
    try expect_formatted("x = [1, 2]\n", "x = [1, 2]\n");
    try expect_formatted("y = (1,)\n", "y = (1,)\n");
}

test "a comment keeps its line and its indentation" {
    try expect_formatted(
        "def f():\n    # leading\n    return 1  # trailing\n",
        "def f():\n    # leading\n    return 1  # trailing\n",
    );

    try expect_formatted("x = 1 # tight\n", "x = 1  # tight\n");
}

test "a python stub with a blank ended comment formats without a dangling line" {
    const source = "# The stub file\n" ++
        "# \n" ++
        "#Generated by SIP\t\n" ++
        "class C:\n" ++
        "    def f(self) -> None: ...  # a \n";

    const expected = "# The stub file\n" ++
        "# \n" ++
        "# Generated by SIP\t\n" ++
        "class C:\n" ++
        "    def f(self) -> None: ...  # a \n";

    try expect_formatted(source, expected);
}

test "a single quoted string becomes a double quoted one" {
    try expect_formatted("x = 'text'\n", "x = \"text\"\n");
    try expect_formatted("x = 'a \"b\"'\n", "x = 'a \"b\"'\n");
    try expect_formatted("x = f'{y}'\n", "x = f\"{y}\"\n");
}

test "a format field takes the spacing its own expression takes" {
    try expect_formatted("x = f'{ a!r :>{width}}'\n", "x = f\"{a!r:>{width}}\"\n");
    try expect_formatted("x = f'{ \"a\" }'\n", "x = f\"{'a'}\"\n");
}

test "a comment at a runs edge stands outside its group" {
    try expect_formatted(
        "g(\n    aaa and bbb  # c\n)\n",
        "g(\n    aaa and bbb  # c\n)\n",
    );

    try expect_formatted(
        "h(\n    # lead\n    aaa and bbb\n)\n",
        "h(\n    # lead\n    aaa and bbb\n)\n",
    );

    try expect_formatted(
        "f(\n    aaa,\n    bbb  # c\n)\n",
        "f(\n    aaa,\n    bbb,  # c\n)\n",
    );
}

test "a yield tuple and a multiline value take their own pair" {
    try expect_formatted(
        "def f():\n    yield \"a\", self.b, None,\n",
        "def f():\n    yield (\n        \"a\",\n        self.b,\n        None,\n    )\n",
    );

    try expect_formatted("def g():\n    x = yield 1,\n", "def g():\n    x = yield (1,)\n");

    try expect_formatted(
        "Event.action.__doc__ = (\"\"\"Executing the event means executing\n" ++
            "action(*argument, **kwargs)\"\"\")\n",
        "Event.action.__doc__ = \"\"\"Executing the event means executing\n" ++
            "action(*argument, **kwargs)\"\"\"\n",
    );
}

test "an operator past a comment leads the line below" {
    const source = "encoded += (\n    b32tab2[c >> 30] +  # bits 1 - 10\n" ++
        "    b32tab2[c & 0x3FF]  # bits 31 - 40\n)\n";

    const wanted = "encoded += (\n    b32tab2[c >> 30]  # bits 1 - 10\n" ++
        "    + b32tab2[c & 0x3FF]  # bits 31 - 40\n)\n";

    try expect_formatted(source, wanted);
}

test "a parted concatenation the join cannot merge keeps its lines" {
    try expect_formatted(
        "a = re.compile(r\"(?:x \"\n    r\".*\"\n    r\"\\[\\]\")\n",
        "a = re.compile(\n    r\"(?:x \"\n    r\".*\"\n    r\"\\[\\]\"\n)\n",
    );

    try expect_formatted("c = (\"x\"\n     \"y\")\n", "c = \"xy\"\n");
    try expect_formatted("d = r\"x\" r\"y\"\n", "d = r\"x\" r\"y\"\n");
}

test "a type parameter and a slice take their own colon spacing" {
    try expect_formatted(
        "def override[F: _Func](method: F, /) -> F:\n    pass\n",
        "def override[F: _Func](method: F, /) -> F:\n    pass\n",
    );

    try expect_formatted("class K[T:int]:\n    pass\n", "class K[T: int]:\n    pass\n");
    try expect_formatted("a = name[len(p)::]\n", "a = name[len(p) : :]\n");
    try expect_formatted("b = name[x() :: 2]\n", "b = name[x() :: 2]\n");
    try expect_formatted("c = name[a:b:c]\n", "c = name[a:b:c]\n");
}

test "a module head comment run keeps its own gaps" {
    try expect_formatted(
        "# a\n\n# b\ndef f():\n    pass\n",
        "# a\n\n# b\ndef f():\n    pass\n",
    );

    try expect_formatted(
        "x = 1\n\n# a\n\n# b\ndef f():\n    pass\n",
        "x = 1\n\n# a\n\n\n# b\ndef f():\n    pass\n",
    );
}

test "an augmented assignment and a walrus header drop a bare pair" {
    try expect_formatted("x += (a + b)\n", "x += a + b\n");
    try expect_formatted("y //= (c)\n", "y //= c\n");
    try expect_formatted("if (a := f()):\n    pass\n", "if a := f():\n    pass\n");
    try expect_formatted("z = (e := j())\n", "z = (e := j())\n");
}

test "a with item list drops a pair the line holds" {
    try expect_formatted(
        "def f():\n    with (open(\"a\") as p, open(\"b\") as q):\n        pass\n",
        "def f():\n    with open(\"a\") as p, open(\"b\") as q:\n        pass\n",
    );

    try expect_formatted(
        "def g():\n    with (\n        open(\"a\") as p,\n    ):\n        pass\n",
        "def g():\n    with (\n        open(\"a\") as p,\n    ):\n        pass\n",
    );
}

test "a with item list takes the pair and a line per item" {
    const source = "def g():\n    with open(src, \"r\", encoding=\"utf-8\") as inn," ++
        " open(dst, \"w\", encoding=\"utf-8\") as out:\n        pass\n";

    const wanted = "def g():\n    with (\n        open(src, \"r\", encoding=\"utf-8\") as inn,\n" ++
        "        open(dst, \"w\", encoding=\"utf-8\") as out,\n    ):\n        pass\n";

    try expect_formatted(source, wanted);
}

test "a width counts the columns a value spells" {
    const held = "\u{df}\u{e0}\u{e1}\u{e2}\u{e3}\u{e4}\u{e5}\u{e6}\u{e7}\u{e8}\u{e9}\u{ea}\\\n" ++
        "                    u{eb}\u{ec}\u{ed}\u{ee}\u{ef}\u{f0}\u{f1}\u{f2}\u{f3}\u{f4}\u{f5}" ++
        "\u{f6}\u{f8}\\\n" ++
        "                    u{f9}\u{fa}\u{fb}\u{fc}\u{fd}\u{fe}\u{ff}";

    const source = "x += \"" ++ held ++ "\"\n";

    try expect_formatted(source, source);
}

test "a trailing comment settles the pair a value takes" {
    const atom = "def f():\n    extended_args_offset = 0" ++
        "  # Number of EXTENDED_ARG instructions preceding the current\n";

    const wanted = "def f():\n    extended_args_offset = (\n        0" ++
        "  # Number of EXTENDED_ARG instructions preceding the current\n    )\n";

    try expect_formatted(atom, wanted);

    const held = "def f():\n    header_value_end_offset = match.start(1) + length - 1" ++
        "  # Last byte of the header xxxx\n";

    const parted_held = "def f():\n    header_value_end_offset = (\n" ++
        "        match.start(1) + length - 1\n" ++
        "    )  # Last byte of the header xxxx\n";

    try expect_formatted(held, parted_held);
}

test "a pragma comment is no part of the width" {
    const source = "def loads(s: str, /, *, parse_float: ParseFloat = float)" ++
        " -> dict[str, Any]:  # noqa: C901\n    pass\n";

    try expect_formatted(source, source);

    const plain = "y = some_function_named(argument_one, argument_two, argument_three, arg_four)" ++
        "  # a remark here\n";

    const wanted = "y = some_function_named(\n" ++
        "    argument_one, argument_two, argument_three, arg_four\n" ++
        ")  # a remark here\n";

    try expect_formatted(plain, wanted);
}

test "a blank line inside a bracket is dropped" {
    try expect_formatted(
        "x = [\n    1,\n    # note\n\n    2,\n]\n",
        "x = [\n    1,\n    # note\n    2,\n]\n",
    );
}

test "a stub holds its blank only ahead of a definition" {
    try expect_formatted(
        "class C:\n    def a(self) -> int: ...\n    x = 1\n",
        "class C:\n    def a(self) -> int: ...\n\n    x = 1\n",
    );

    try expect_formatted(
        "class D:\n    def a(self) -> int: ...\n    def b(self) -> str: ...\n",
        "class D:\n    def a(self) -> int: ...\n    def b(self) -> str: ...\n",
    );
}

test "a parted list writes its separator ahead of a comment" {
    const long = "\"" ++ @as([77]u8, @splat('a')) ++ "\"";

    try expect_formatted(
        "f(\n    " ++ long ++ ",\n    \"b\"  # note\n)\n",
        "f(\n    " ++ long ++ ",\n    \"b\",  # note\n)\n",
    );
}

test "a lambda body takes the pair its width needs" {
    const source = "f(\n    \"a\",\n    b,\n    lambda name: name.isupper() and " ++
        "(name.startswith(\"SIG\")" ++
        " and not name.startswith(\"SIG_\")) or name.startswith(\"CTRL_\"),\n)\n";

    const wanted = "f(\n    \"a\",\n    b,\n    lambda name: (\n        name.isupper()\n" ++
        "        and (name.startswith(\"SIG\") and not name.startswith(\"SIG_\"))\n" ++
        "        or name.startswith(\"CTRL_\")\n    ),\n)\n";

    try expect_formatted(source, wanted);
    try expect_formatted("g = lambda o: o.pk\n", "g = lambda o: o.pk\n");
}

test "a parenthesized lambda formats without an open group" {
    try expect_formatted("q = (lambda: g())\n", "q = lambda: g()\n");
    try expect_formatted("q = (lambda: \"x\" \"y\")  # c\n", "q = lambda: \"xy\"  # c\n");

    try expect_formatted(
        "if x:\n    q = (\n        lambda x: f(x) % x\n    )  # noqa: E731\n",
        "if x:\n    q = lambda x: f(x) % x  # noqa: E731\n",
    );
}

test "a class head and an except clause drop a bare pair" {
    try expect_formatted("class A():\n    pass\n", "class A:\n    pass\n");
    try expect_formatted("class B(object):\n    pass\n", "class B(object):\n    pass\n");

    try expect_formatted(
        "try:\n    pass\nexcept (E):\n    pass\n",
        "try:\n    pass\nexcept E:\n    pass\n",
    );

    try expect_formatted(
        "try:\n    pass\nexcept (F, G):\n    pass\n",
        "try:\n    pass\nexcept (F, G):\n    pass\n",
    );
}

test "a bare tuple target takes the parentheses" {
    try expect_formatted("a, = xs\n", "(a,) = xs\n");
    try expect_formatted("b, c = xs\n", "b, c = xs\n");
    try expect_formatted("d, = e, = xs\n", "(d,) = (e,) = xs\n");
    try expect_formatted("for f, in xs:\n    pass\n", "for (f,) in xs:\n    pass\n");
    try expect_formatted("for (g, h) in xs:\n    pass\n", "for g, h in xs:\n    pass\n");
    try expect_formatted("for (i,) in xs:\n    pass\n", "for (i,) in xs:\n    pass\n");
}

test "a redundant semicolon is dropped" {
    try expect_formatted("a = 1;\n", "a = 1\n");
    try expect_formatted("b = 2; c = 3;\n", "b = 2\nc = 3\n");
    try expect_formatted("if x:\n    d = 4;\n", "if x:\n    d = 4\n");
}

test "a trailing comment closes the groups it stands past" {
    const source = "def f():\n    def g():\n        return (\n" ++
        "            value in cls._unhashables_  # both are lists\n" ++
        "            or value in cls._hashables_\n        )\n";

    try expect_formatted(source, source);
}

test "a tripled body swaps its quote past an escaped one" {
    try expect_formatted("x = '''it\\'s'''", "x = \"\"\"it\\'s\"\"\"\n");
    try expect_formatted("x = '''q \" end'''\n", "x = \"\"\"q \" end\"\"\"\n");
    try expect_formatted("x = '''ends \"'''\n", "x = '''ends \"'''\n");
}

test "a raw string swaps its quote past an escaped one" {
    try expect_formatted("x = r'a\\\"b'", "x = r\"a\\\"b\"\n");
    try expect_formatted("x = r'a\"b'\n", "x = r'a\"b'\n");
    try expect_formatted("x = r'a\\\"b\"c'", "x = r'a\\\"b\"c'\n");
}

test "a power operand is read inside its own line" {
    try expect_formatted(
        "l = l * f**n\nshapesize(l / 100.0)\n",
        "l = l * f**n\nshapesize(l / 100.0)\n",
    );

    try expect_formatted("x = f(a) ** 2\n", "x = f(a) ** 2\n");
    try expect_formatted("g(a)\nx = b**2\n", "g(a)\nx = b**2\n");
}

test "a negated power closes its parentheses behind its whole operand" {
    try expect_formatted("x = -a ** f\"{b}\"\n", "x = -(a ** f\"{b}\")\n");
    try expect_formatted("x = -a ** \"s\" \"t\"\n", "x = -(a ** \"st\")\n");
    try expect_formatted("x = -a ** 2 if c else d\n", "x = -(a**2) if c else d\n");
    try expect_formatted("x = [-a ** 2 for y in z]\n", "x = [-(a**2) for y in z]\n");
    try expect_formatted("x = -a ** 2\ny = -b ** 3\n", "x = -(a**2)\ny = -(b**3)\n");
}

test "a negation parenthesizes only the power it holds directly" {
    try expect_formatted("x = not a ** 2 == b\n", "x = not a**2 == b\n");
    try expect_formatted("x = not a ** 2\n", "x = not (a**2)\n");
    try expect_formatted("x = not -a ** 2\n", "x = not -(a**2)\n");
    try expect_formatted("x = - - a ** 2\n", "x = --(a**2)\n");
    try expect_formatted("x = y is not a ** 2\n", "x = y is not a**2\n");
    try expect_formatted("x = -a ** -b ** 2\n", "x = -(a ** -(b**2))\n");
}

test "a power hugs only operands ruff calls simple" {
    try expect_formatted("x = a ** None\n", "x = a**None\n");
    try expect_formatted("x = a ** ~b\n", "x = a**~b\n");
    try expect_formatted("x = await a ** 2\n", "x = await a ** 2\n");
    try expect_formatted("x = a ** -b ** c\n", "x = a ** -(b**c)\n");
}

test "an assert message parenthesizes itself once the test has broken" {
    const head = "class C:\n    def f():\n" ++
        "        assert not (base_url or subdomain or url_scheme) or " ++
        "(base_url is not None) != bool(subdomain or url_scheme), ";

    const tested = "class C:\n    def f():\n" ++
        "        assert not (base_url or subdomain or url_scheme) or (\n" ++
        "            base_url is not None\n        ) != bool(subdomain or url_scheme), ";

    const message = "'Cannot pass \"subdomain\" or \"url_scheme\" with \"base_url\".'";
    const wrapped = "(\n            " ++ message ++ "\n        )\n";

    try expect_formatted(head ++ message ++ "\n", tested ++ wrapped);
    try expect_formatted(head ++ "(" ++ message ++ ")\n", tested ++ wrapped);
    try expect_formatted(head ++ "(message)\n", tested ++ "message\n");
    try expect_formatted(head ++ "(\"a \" \"b\")\n", tested ++ "\"a b\"\n");
}

test "an augmented assignment wraps its value and never the statement" {
    try expect_formatted(
        "x <<= aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, bbbbbbbbbbb" ++
            "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb, c\n",
        "x <<= (\n" ++
            "    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa,\n" ++
            "    bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb,\n" ++
            "    c,\n" ++
            ")\n",
    );

    try expect_formatted(
        "x |= aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa == bbbbbbb" ++
            "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n",
        "x |= (\n" ++
            "    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n" ++
            "    == bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n" ++
            ")\n",
    );
}

test "a for iterable takes optional parentheses when it holds an operator" {
    try expect_formatted(
        "for x in aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ++
            "aaaaaaaaa + bbbbbbbbbbbbbbbbbbbb:\n" ++
            "    pass\n",
        "for x in (\n" ++
            "    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ++
            "aaaa + bbbbbbbbbbbbbbbbbbbb\n" ++
            "):\n" ++
            "    pass\n",
    );
}

test "a comment behind an operator breaks the rest of its segment" {
    try expect_formatted(
        "v = (\n" ++
            "    \"a\"  # one\n" ++
            "    \"b\" +  # two\n" ++
            "    # three\n" ++
            "    f(k) + \"c\"\n" ++
            ")\n",
        "v = (\n" ++
            "    \"a\"  # one\n" ++
            "    \"b\" +  # two\n" ++
            "    # three\n" ++
            "    f(k)\n" ++
            "    + \"c\"\n" ++
            ")\n",
    );
}

test "a replacement field spaces a power the way its statement would" {
    try expect_formatted("x = f\"{f(a, **k)}\"\n", "x = f\"{f(a, **k)}\"\n");
    try expect_formatted("x = f\"{ {**a, **b} }\"\n", "x = f\"{ {**a, **b} }\"\n");
    try expect_formatted("x = f\"{a ** f(b)}\"\n", "x = f\"{a ** f(b)}\"\n");
    try expect_formatted("x = f\"{a ** b}\"\n", "x = f\"{a**b}\"\n");
    try expect_formatted("x = f\"{-a ** 2}\"\n", "x = f\"{-(a**2)}\"\n");
    try expect_formatted("x = f\"{not a ** 2}\"\n", "x = f\"{not (a**2)}\"\n");
}

test "a comment trailing a module docstring keeps its own gap" {
    try expect_formatted(
        "\"\"\"Doc.\"\"\"\n# c\n\nx = 1\n",
        "\"\"\"Doc.\"\"\"\n# c\n\nx = 1\n",
    );

    try expect_formatted(
        "\"\"\"Doc.\"\"\"\n# c\nx = 1\n",
        "\"\"\"Doc.\"\"\"\n\n# c\nx = 1\n",
    );

    try expect_formatted(
        "\"\"\"Doc.\"\"\"\n# c\n\n# d\nx = 1\n",
        "\"\"\"Doc.\"\"\"\n# c\n\n# d\nx = 1\n",
    );

    try expect_formatted(
        "class C:\n    \"\"\"Doc.\"\"\"\n    # c\n\n    x = 1\n",
        "class C:\n    \"\"\"Doc.\"\"\"\n\n    # c\n\n    x = 1\n",
    );
}

test "a quote preference reaches inside a replacement field" {
    try expect_formatted(
        "x = f'{c.__name__}({\", \".join(v)})'\n",
        "x = f\"{c.__name__}({', '.join(v)})\"\n",
    );

    try expect_formatted("x = f'a \"q\" {d[\'k\']}'\n", "x = f'a \"q\" {d[\"k\"]}'\n");
    try expect_formatted("x = f'{f\"{y}\"}'\n", "x = f\"{f'{y}'}\"\n");
    try expect_formatted("x = f'{y:{\"w\"}}'\n", "x = f\"{y:{\"w\"}}\"\n");

    try expect_formatted(
        "x = f'{d[\"a\"]}' f'{d[\"b\"]}'\n",
        "x = f\"{d['a']}{d['b']}\"\n",
    );
}
