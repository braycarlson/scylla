const std = @import("std");
const assert = std.debug.assert;
const Emitter = @import("../python.zig").Emitter;
const Kind = @import("../python.zig").Kind;
const Powers = @import("power.zig").Powers;
const Span = @import("../../stdx/bounded/span.zig");
const bracket_depth_max = @import("../python.zig").bracket_depth_max;
const ends_operand = @import("../python.zig").ends_operand;
const escapes_of = @import("literal.zig").escapes_of;
const format_nest_max = @import("../python.zig").format_nest_max;
const is_close = @import("../python.zig").is_close;
const is_layout = @import("../python.zig").is_layout;
const is_number = @import("../python.zig").is_number;
const is_open = @import("../python.zig").is_open;
const numbered = @import("literal.zig").numbered;
const other_quote = @import("literal.zig").other_quote;
const paren_close = @import("../python.zig").paren_close;
const paren_head = @import("../python.zig").paren_head;
const paren_open = @import("../python.zig").paren_open;
const power = @import("power.zig");
const preferring = @import("literal.zig").preferring;
const prefix_of = @import("literal.zig").prefix_of;
const prefix_written = @import("literal.zig").prefix_written;
const quoted_body = @import("literal.zig").quoted_body;
const relettered = @import("literal.zig").relettered;
const signed = @import("../python.zig").signed;
const slice = @import("slice.zig");
const triple_double = @import("literal.zig").triple_double;
const triple_single = @import("literal.zig").triple_single;
const unescaped = @import("literal.zig").unescaped;
const worded = @import("../python.zig").worded;

const DebugQuotes = struct {
    double: bool,
    single: bool,

    fn holds(quotes: DebugQuotes, quote: u8) bool {
        assert(quote == '"' or quote == '\'');

        return if (quote == '"') quotes.double else quotes.single;
    }
};

const QuoteTally = struct {
    alone: u32,
    wanted: u32,
};

const Field = struct {
    converted: bool,
    hugged: bool,
    lambda: bool,
    leftmost: bool,
    mapped: bool,
    operand: bool,
    prefixed: bool,
    spec: bool,
    stacked: bool,
    tupled: ?u32,

    const none: Field = .{
        .converted = false,
        .hugged = false,
        .lambda = false,
        .leftmost = false,
        .mapped = false,
        .operand = false,
        .prefixed = false,
        .spec = false,
        .stacked = false,
        .tupled = null,
    };
};

const Nest = struct {
    base: u32,
    field: Field,
    quote: u8,
    raw: bool,
    want: u8,

    const none: Nest = .{
        .base = 0,
        .field = .none,
        .quote = 0,
        .raw = false,
        .want = 0,
    };
};

pub const Fields = struct {
    brackets: [bracket_depth_max]Kind,
    depth: u32,
    formats: u32,
    held: Field,
    nests: [format_nest_max]Nest,
    powers: Powers,
    previous: ?Kind,

    pub const none: Fields = .{
        .brackets = @splat(.brace_open),
        .depth = 0,
        .formats = 0,
        .held = .none,
        .nests = @splat(.none),
        .powers = .empty,
        .previous = null,
    };
};

fn format_quote_count(body: []const u8, quote: u8, raw: bool) u32 {
    assert(quote == '"' or quote == '\'');
    assert(body.len <= std.math.maxInt(u32));

    if (raw) return @intFromBool(unescaped(body, quote));
    return escapes_of(body, quote);
}

fn fielding(
    kind: Kind,
    previous: ?Kind,
    brackets: []Kind,
    depth: *u32,
    held: *Field,
) error{Overflow}!void {
    assert(brackets.len == bracket_depth_max);
    assert(kind.is_token());
    if (previous) |unwrapped| assert(unwrapped.is_token());

    if (is_open(kind)) {
        if (depth.* == bracket_depth_max) return error.Overflow;

        const specced = kind == .brace_open and (held.spec or previous == .colon);

        brackets[depth.*] = if (specced) .colon else kind;
        depth.* += 1;
    }

    if (is_close(kind)) {
        const inner = depth.* -| 1;

        held.stacked = depth.* > 1 and brackets[inner] != .colon;
        depth.* = inner;
    }

    const bodied = previous == .colon;
    const at = depth.*;

    held.lambda = kind == .lambda_keyword or (held.lambda and !bodied);
    held.mapped = at > 1 and brackets[at - 1] == .brace_open;
    held.converted = at > 0 and (held.converted or (kind == .bang and at == 1));
    held.prefixed = signed(kind) and !held.operand;
    held.spec = at > 0 and (held.spec or (kind == .colon and at == 1));
    held.operand = ends_operand(kind);

    assert(depth.* <= bracket_depth_max);
    if (held.mapped) assert(depth.* > 1);
}

fn fielded(previous: Kind, kind: Kind, held: Field, hugs: bool) bool {
    assert(previous.is_token());
    assert(kind.is_token());
    if (held.leftmost) assert(held.tupled == null);

    const braces_open = previous == .brace_open and kind == .brace_open;
    const braces_close = previous == .brace_close and kind == .brace_close and held.stacked;

    if (braces_open) return true;
    if (braces_close) return true;
    if (is_open(previous)) return false;
    if (is_close(kind)) return false;
    if (held.prefixed) return false;
    if (kind == .comma) return false;
    if (kind == .dot) return false;
    if (kind == .semicolon) return false;
    if (previous == .dot) return false;
    if (kind == .colon) return false;
    if (previous == .colon) return held.lambda or held.mapped;
    if (kind == .star_star) return !held.operand or !hugs;
    if (previous == .star_star) return !held.hugged;
    if (fielded_tight(kind)) return false;
    if (fielded_tight(previous)) return false;
    if (worded(previous)) return true;
    if (worded(kind)) return true;
    if (is_open(kind)) return !held.operand;
    return true;
}

fn fielded_tight(kind: Kind) bool {
    assert(kind.is_token());

    const result = switch (kind) {
        .bang, .equal => true,
        else => false,
    };

    if (result) assert(kind.is_token());
    if (result) assert(!ends_operand(kind));

    return result;
}

fn format_quote(emitter: *const Emitter, position: u32, preference: u8) u8 {
    assert(position < emitter.raw.len);
    assert(emitter.raw[position] == .f_string_start);
    assert(preference == '"' or preference == '\'');

    const opening = emitter.tokens[position];
    const spelling = emitter.source[opening.offset..opening.end()];
    const at = prefix_of(spelling);
    const rest = spelling[at..];
    const tripled_double = std.mem.startsWith(u8, rest, triple_double);
    const tripled_single = std.mem.startsWith(u8, rest, triple_single);

    if (preference == 0) return 0;
    if (tripled_double) return 0;
    if (tripled_single) return 0;

    const end = emitter.fstring_end(position) orelse return 0;
    const raw = std.mem.findAny(u8, spelling[0..at], "Rr") != null;
    const other = other_quote(preference);
    const tally = format_quote_tally(emitter, position, end, raw, preference);

    assert(rest.len > 0);

    const debugged = debug_quotes(emitter, position, end);

    const chosen = if (raw) quote: {
        if (tally.wanted == 0) break :quote preference;
        if (tally.alone == 0) break :quote other;

        break :quote rest[0];
    } else if (tally.alone < tally.wanted) other else preference;

    if (debugged.holds(chosen)) return 0;
    return chosen;
}

fn debug_quotes(emitter: *const Emitter, position: u32, end: u32) DebugQuotes {
    assert(position < end);
    assert(emitter.raw[position] == .f_string_start);

    var quotes: DebugQuotes = .{ .double = false, .single = false };
    var formats: u32 = 0;
    var scan = position;

    while (scan <= end) : (scan += 1) {
        const kind = emitter.raw[scan];

        formats += @intFromBool(kind == .f_string_start);
        formats -= @intFromBool(kind == .f_string_end);

        if (formats != 1) continue;
        if (kind != .brace_open) continue;

        const close = debug_close(emitter, scan) orelse continue;
        const verbatim = emitter.source[emitter.tokens[scan].offset..emitter.tokens[close].end()];

        quotes.double = quotes.double or std.mem.findScalar(u8, verbatim, '"') != null;
        quotes.single = quotes.single or std.mem.findScalar(u8, verbatim, '\'') != null;
        scan = close;
    }

    return quotes;
}

fn debug_close(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.raw.len);
    assert(emitter.raw[position] == .brace_open);

    const count: u32 = @intCast(emitter.tokens.len);
    var debug = false;
    var depth: u32 = 0;
    var formats: u32 = 0;
    var scan = position + 1;

    while (scan < count) : (scan += 1) {
        const kind = emitter.raw[scan];

        if (kind == .f_string_start) formats += 1;

        if (kind == .f_string_end) {
            if (formats == 0) return null;

            formats -= 1;

            continue;
        }

        if (formats > 0) continue;

        if (depth == 0) {
            if (kind == .brace_close) return if (debug) scan else null;

            debug = debug or kind == .equal;

            const specified = kind == .bang or kind == .colon;

            if (specified) {
                if (!debug) return null;
            }
        }

        if (is_open(kind)) depth += 1;
        if (is_close(kind)) depth -|= 1;
    }

    return null;
}

fn format_quote_tally(
    emitter: *const Emitter,
    position: u32,
    end: u32,
    raw: bool,
    preference: u8,
) QuoteTally {
    assert(position <= end);
    assert(end < emitter.raw.len);
    assert(preference == '"' or preference == '\'');

    const other = other_quote(preference);
    var depth: u32 = 0;
    var scan = position;
    var tally: QuoteTally = .{ .alone = 0, .wanted = 0 };

    while (scan <= end) : (scan += 1) {
        const kind = emitter.raw[scan];

        depth += @intFromBool(kind == .f_string_start);

        const counted = kind == .f_string_middle and depth == 1;

        if (counted) {
            const middle = emitter.tokens[scan];
            const body = emitter.source[middle.offset..middle.end()];

            tally.alone += format_quote_count(body, other, raw);
            tally.wanted += format_quote_count(body, preference, raw);
        }

        depth -= @intFromBool(kind == .f_string_end);
    }

    assert(depth == 0);

    return tally;
}

fn opens_format(emitter: *Emitter, position: u32, preference: u8) error{Overflow}!u8 {
    assert(position < emitter.raw.len);
    assert(emitter.raw[position] == .f_string_start);
    assert(preference == '"' or preference == '\'');

    const opening = emitter.tokens[position];
    const spelling = emitter.source[opening.offset..opening.end()];
    const at = prefix_of(spelling);
    const quote = format_quote(emitter, position, preference);

    if (quote == 0) {
        try emitter.arena.push(spelling);

        return 0;
    }

    const prefix = prefix_written(spelling[0..at]);

    try emitter.arena.push(prefix.written[0..prefix.count]);
    try emitter.arena.push_byte(quote);

    return quote;
}

pub fn respaced(emitter: *Emitter, position: u32, end: u32) ?Span {
    assert(position <= end);
    assert(end < emitter.tokens.len);

    const bytes = emitter.source[emitter.tokens[position].offset..emitter.tokens[end].end()];
    const offset = emitter.arena.count();

    const refit = refielded(emitter, position, end, 0) catch |err| switch (err) {
        error.Overflow => false,
    };

    if (!refit) {
        emitter.arena.truncate(offset);

        return null;
    }

    return emitter.written(offset, bytes);
}

pub fn refielded(emitter: *Emitter, position: u32, end: u32, imposed: u8) error{Overflow}!bool {
    assert(position <= end);
    assert(end < emitter.tokens.len);
    assert(imposed == 0 or imposed == '"' or imposed == '\'');

    var state: Fields = .none;
    var scan = position;

    while (scan <= end) : (scan += 1) {
        const kind = emitter.raw[scan];
        const piece = emitter.tokens[scan];
        const spelling = emitter.source[piece.offset..piece.end()];
        const lined = std.mem.findScalar(u8, spelling, '\n');
        const multiline = kind != .f_string_middle and lined != null;
        if (multiline) return false;
        if (kind == .comment) return false;

        const field_opens = kind == .brace_open and state.depth == 0 and state.formats > 0;

        if (field_opens) {
            if (debug_close(emitter, scan)) |close| {
                const verbatim = emitter.source[piece.offset..emitter.tokens[close].end()];
                const quote = state.nests[state.formats - 1].quote;
                const clashes = quote != 0 and std.mem.findScalar(u8, verbatim, quote) != null;
                if (clashes) return false;

                const blank = if (state.previous) |word|
                    fielded(word, kind, state.held, false)
                else
                    false;

                if (blank) try emitter.arena.push(" ");

                try emitter.arena.push(verbatim);

                state.held = .none;
                state.held.operand = true;
                state.previous = .brace_close;
                scan = close;

                continue;
            }
        }

        const fitted = switch (kind) {
            .f_string_end, .f_string_middle, .f_string_start => try renested(
                emitter,
                scan,
                imposed,
                &state,
            ),
            else => try refield(emitter, scan, &state),
        };

        if (!fitted) return false;

        for (0..bracket_depth_max) |_| {
            if (!state.powers.closes(scan)) break;

            try emitter.arena.push(paren_close);

            state.previous = .paren_close;
        }
    }

    assert(state.formats <= format_nest_max);

    return state.formats == 0;
}

fn renested(
    emitter: *Emitter,
    position: u32,
    imposed: u8,
    state: *Fields,
) error{Overflow}!bool {
    assert(position < emitter.raw.len);
    assert(state.formats <= format_nest_max);
    assert(imposed == 0 or imposed == '"' or imposed == '\'');

    const kind = emitter.raw[position];

    if (kind == .f_string_start) {
        if (state.formats == format_nest_max) return error.Overflow;

        const field = state.held;
        const blank = if (state.previous) |word| fielded(word, kind, field, false) else false;

        if (blank) try emitter.arena.push(" ");

        try opens_nest(emitter, position, imposed, state);

        return true;
    }

    if (state.formats == 0) return false;

    const inner = state.formats - 1;
    const nest = state.nests[inner];
    const piece = emitter.tokens[position];
    const spelling = emitter.source[piece.offset..piece.end()];

    if (kind == .f_string_middle) {
        const plain = nest.quote == 0 or nest.raw;

        if (plain) {
            try emitter.arena.push(spelling);
        } else {
            try quoted_body(emitter.arena, spelling, nest.quote, true);
        }

        if (state.depth == nest.base) state.held = .none;

        state.previous = null;

        return true;
    }

    const imposing = inner == 0 and imposed != 0;

    if (!imposing) {
        if (nest.quote == 0) {
            try emitter.arena.push(spelling);
        } else {
            try emitter.arena.push_byte(nest.quote);
        }
    }

    state.depth = nest.base;
    state.formats = inner;
    state.held = nest.field;
    state.held.operand = true;
    state.held.prefixed = false;
    state.previous = if (inner > 0) .f_string_end else null;

    assert(state.formats < format_nest_max);

    return true;
}

fn opens_nest(
    emitter: *Emitter,
    position: u32,
    imposed: u8,
    state: *Fields,
) error{Overflow}!void {
    assert(state.formats < format_nest_max);
    assert(emitter.raw[position] == .f_string_start);
    assert(imposed == 0 or imposed == '"' or imposed == '\'');

    const opening = emitter.tokens[position];
    const spelling = emitter.source[opening.offset..opening.end()];
    const formats = state.formats;
    const preference = emitter.quote.byte();
    const outer = if (formats == 0) preference else state.nests[formats - 1].want;
    const imposing = formats == 0 and imposed != 0;
    const quote = if (imposing) imposed else try opens_format(emitter, position, outer);
    const raw = std.mem.findAny(u8, spelling[0..prefix_of(spelling)], "Rr") != null;

    state.nests[formats] = .{
        .base = state.depth,
        .field = state.held,
        .quote = quote,
        .raw = raw,
        .want = if (quote == 0) outer else other_quote(quote),
    };

    state.depth = 0;
    state.formats = formats + 1;
    state.held = .none;
    state.previous = null;

    assert(state.formats <= format_nest_max);
}

fn refield(emitter: *Emitter, position: u32, state: *Fields) error{Overflow}!bool {
    assert(position < emitter.raw.len);
    assert(state.formats <= format_nest_max);

    if (state.formats == 0) return false;

    const kind = emitter.raw[position];
    const piece = emitter.tokens[position];
    const spelling = emitter.source[piece.offset..piece.end()];
    const hugs = kind == .star_star and power.hugs(emitter, position);
    const closes_field = kind == .brace_close and state.depth == 1;

    const blank = if (closes_field)
        state.held.leftmost and !state.held.spec and !state.held.converted
    else
        sliced_space(emitter, position, state.previous) orelse
            if (state.previous) |word| fielded(word, kind, state.held, hugs) else false;

    const powered_end = power.powered(emitter, position, state.previous);

    if (blank) try emitter.arena.push(" ");
    if (state.held.tupled == position) try emitter.arena.push(")");

    const opens = kind == .brace_open and state.depth == 0;
    const want = state.nests[state.formats - 1].want;
    const stringed = kind == .string_bytes or kind == .string_plain;
    const requotes = !state.held.spec and want != 0 and stringed;

    if (requotes) {
        try relettered(emitter.arena, spelling, preferring(want));
    } else if (is_number(kind)) {
        try numbered(emitter.arena, spelling);
    } else {
        try emitter.arena.push(spelling);
    }

    try fielding(kind, state.previous, &state.brackets, &state.depth, &state.held);

    state.held.hugged = hugs;

    if (opens) {
        state.held.tupled = field_tuple(emitter, position);

        state.held.leftmost = state.held.tupled == null and
            emitter.next_kind(position) == .brace_open;
    }

    state.previous = kind;

    if (opens) {
        if (state.held.tupled != null) {
            try emitter.arena.push("(");

            state.previous = .paren_open;
        }
    }

    if (powered_end) |end| {
        const negated = kind == .not_keyword;

        try state.powers.push(end);
        try emitter.arena.push(if (negated) paren_open else paren_head);

        state.previous = .paren_open;
    }

    return true;
}

fn sliced_space(emitter: *const Emitter, position: u32, previous: ?Kind) ?bool {
    assert(position < emitter.raw.len);
    assert(emitter.raw.len == emitter.tokens.len);
    if (previous) |held| assert(held.is_token());

    const word = previous orelse return null;
    const kind = emitter.raw[position];
    if (is_close(kind)) return null;

    if (kind == .colon) {
        const complex = slice.colon(emitter, position) orelse return null;

        if (word == .comma) return true;
        if (word == .colon) return complex and emitter.next_kind(position) == .bracket_close;
        return complex and !is_open(word);
    }

    if (word != .colon) return null;
    if (position == 0) return null;

    const colon = significant_previous(emitter, position) orelse return null;
    if (emitter.raw[colon] != .colon) return null;

    const complex = slice.colon(emitter, colon) orelse return null;
    return complex and kind != .colon;
}

fn significant_previous(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.raw.len);
    assert(position > 0);

    var scan = position;

    while (scan > 0) {
        scan -= 1;

        if (!is_layout(emitter.raw[scan])) return scan;
    }

    return null;
}

pub fn field_tuple(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.raw.len);
    assert(emitter.raw[position] == .brace_open);

    const count: u32 = @intCast(emitter.tokens.len);
    var comma_at: ?u32 = null;
    var depth: u32 = 0;
    var last: ?u32 = null;
    var scan = position + 1;

    while (scan < count) : (scan += 1) {
        const kind = emitter.raw[scan];
        if (is_layout(kind)) continue;

        const equals = depth == 0 and kind == .equal;
        const ended = depth == 0 and (is_close(kind) or kind == .bang or kind == .colon);

        if (equals) return null;
        if (ended) return if (comma_at == last) scan else null;

        if (is_open(kind)) depth += 1;
        if (is_close(kind)) depth -= 1;

        const separated = depth == 0 and kind == .comma;

        if (separated) {
            if (comma_at != null) return null;

            comma_at = scan;
        }

        last = scan;
    }

    return null;
}

test "a field tracks its brackets and the spacing inside them" {
    var state: Fields = .none;

    try fielding(.brace_open, null, &state.brackets, &state.depth, &state.held);
    try std.testing.expectEqual(@as(u32, 1), state.depth);
    try std.testing.expectEqual(Kind.brace_open, state.brackets[0]);
    try fielding(.identifier, .brace_open, &state.brackets, &state.depth, &state.held);
    try std.testing.expect(state.held.operand);
    try fielding(.colon, .identifier, &state.brackets, &state.depth, &state.held);
    try std.testing.expect(state.held.spec);
    try fielding(.brace_open, .colon, &state.brackets, &state.depth, &state.held);
    try std.testing.expectEqual(Kind.colon, state.brackets[1]);
    try std.testing.expect(!state.held.mapped);
    try fielding(.brace_close, .brace_open, &state.brackets, &state.depth, &state.held);
    try std.testing.expect(!state.held.stacked);
    try std.testing.expectEqual(@as(u32, 1), state.depth);
    try fielding(.lambda_keyword, .comma, &state.brackets, &state.depth, &state.held);
    try std.testing.expect(state.held.lambda);
    try fielding(.minus, .colon, &state.brackets, &state.depth, &state.held);
    try std.testing.expect(!state.held.lambda);
    try std.testing.expect(state.held.prefixed);

    state.depth = bracket_depth_max;

    const deep = fielding(.paren_open, .comma, &state.brackets, &state.depth, &state.held);

    try std.testing.expectError(error.Overflow, deep);
    try std.testing.expectEqual(bracket_depth_max, state.depth);
}

test "a field blank stands where the field spacing puts one" {
    var in_lambda: Field = .none;
    var in_operand: Field = .none;

    in_lambda.lambda = true;
    in_operand.operand = true;

    try std.testing.expect(fielded(.brace_open, .brace_open, .none, false));
    try std.testing.expect(!fielded(.identifier, .comma, .none, false));
    try std.testing.expect(fielded(.identifier, .plus, .none, false));
    try std.testing.expect(fielded(.colon, .identifier, in_lambda, false));
    try std.testing.expect(!fielded(.colon, .identifier, .none, false));
    try std.testing.expect(!fielded(.identifier, .equal, .none, false));
    try std.testing.expect(!fielded(.identifier, .paren_open, in_operand, false));
    try std.testing.expect(fielded(.identifier, .paren_open, .none, false));
    try std.testing.expect(fielded(.identifier, .in_keyword, in_operand, false));
    try std.testing.expect(!fielded(.paren_open, .identifier, .none, false));
    try std.testing.expect(fielded(.comma, .star_star, .none, false));
    try std.testing.expect(!fielded(.identifier, .star_star, in_operand, true));
    try std.testing.expect(fielded(.identifier, .star_star, in_operand, false));
}
