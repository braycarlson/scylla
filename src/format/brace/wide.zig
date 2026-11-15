const std = @import("std");
const assert = std.debug.assert;
const Token = @import("../../syntax/token.zig");
const bind = @import("bind.zig");
const body = @import("body.zig");
const brace = @import("../brace.zig");
const call = @import("call.zig");
const closure = @import("closure.zig");
const comment = @import("comment.zig");
const core = @import("emitter.zig");
const edge = @import("edge.zig");
const emit = @import("emit.zig");
const header = @import("header.zig");
const join = @import("join.zig");
const line = @import("line.zig");
const list = @import("list.zig");
const own = @import("own.zig");
const payload = @import("payload.zig");
const reach = @import("../reach.zig");
const sole = @import("sole.zig");
const split = @import("split.zig");
const tmpl = @import("tmpl.zig");
const walk = @import("../walk.zig");
const word_in = @import("../../text/scan.zig").word_in;
const wrap = @import("wrap.zig");
const Emitter = core.Emitter;

const ListCommas = struct {
    close: u32,
    depth: u32,
    lambda: bool,
    prior: ?u32,
    scan: u32,

    fn step(walker: *ListCommas, emitter: *const Emitter) ?u32 {
        assert(walker.close < emitter.count);
        assert(walker.scan <= walker.close);

        while (walker.scan < walker.close) {
            const scan = walker.scan;
            const token = emitter.tokens[scan];
            const kind = token.kind;
            const opens = operand_opens(emitter, walker.prior);

            walker.scan += 1;

            if (token.length > 0) walker.prior = scan;

            const barring = walker.depth == 0 and text_is(emitter, scan, "|");
            const toggles = barring and (walker.lambda or opens);

            if (toggles) {
                walker.lambda = !walker.lambda;
            } else if (walk.is_open(kind)) {
                walker.depth += 1;
            } else if (walk.is_close(kind)) {
                walker.depth -|= 1;
            } else {}

            const separates = walker.depth == 0 and !walker.lambda and token.is_punctuation(.comma);
            if (!separates) continue;
            if (join.angle_head(emitter, scan) == null) return scan;
        }

        return null;
    }
};

const FieldFrame = struct {
    depth: u32,
    range: FieldRange,
    returned: bool,
    scan: u32,
};

pub const FieldRange = struct {
    first: u32,
    last: u32,
};

const Listed = struct {
    close: u32,
    held: u32,
    open: u32,
    overflowed: bool,
    rooted: bool,
    stop: u32,
};

pub const Listing = struct {
    close: u32,
    open: u32,
    shut: u32,
    target: u32,
    defined: bool,
    phase: ListingPhase,
};

const ListingPhase = enum {
    braced,
    hugged,
    open,
    start,
};

pub const Probe = struct {
    admitted: bool,
    kind: ProbeKind,
    open: u32,
    over: bool,
    point: u32,
    scan: u32,
    stage: u8,
};

const ProbeKind = enum(u8) {
    block,
    braced_line,
    branched,
    chained_line,
    chained_over,
    literal,
    root_lined,
};

const Rooting = union(enum) {
    back: u32,
    verdict: bool,
};

const Stream = struct {
    blocked: u64,
    blocks: u32,
    depth: u32,
    lambda: bool,
    prior: ?u32,

    const empty: Stream = .{
        .blocked = 0,
        .blocks = 0,
        .depth = 0,
        .lambda = false,
        .prior = null,
    };

    fn braced(stream: *const Stream) bool {
        assert(stream.depth <= std.math.maxInt(u32));

        if (stream.depth == 0) return false;
        if (stream.depth > macro_level_max) return false;

        const bit = @as(u64, 1) << @intCast(stream.depth - 1);
        return stream.blocked & bit != 0;
    }

    fn nest(stream: *Stream, emitter: *const Emitter, position: u32) void {
        assert(position < emitter.count);

        const kind = emitter.tokens[position].kind;
        const opens = walk.is_open(kind) or kind == .block_start;
        const closes = walk.is_close(kind) or kind == .block_end;

        if (opens) {
            stream.depth += 1;
            stream.blocks += @intFromBool(kind == .block_start);

            assert(stream.depth > 0);

            if (stream.depth <= macro_level_max) {
                const bit = @as(u64, 1) << @intCast(stream.depth - 1);

                if (kind == .block_start) {
                    stream.blocked |= bit;
                } else {
                    stream.blocked &= ~bit;
                }
            }
        } else if (closes) {
            stream.depth -|= 1;
            stream.blocks -|= @intFromBool(kind == .block_end);
        } else {}
    }
};

const arm_arrow_owed: u32 = 4;
const binding_patterns: []const []const u8 = &.{ "const", "let", "var" };
const block_words: []const []const u8 = &.{ "async", "const", "gen", "move", "try", "unsafe" };
const bound_words: []const []const u8 = &.{ "=", "=>", "in" };
const branch_last_words: []const []const u8 = &.{ "for", "if", "loop", "match", "while" };

const branch_openers: []const []const u8 = &.{
    "async",
    "const",
    "do",
    "gen",
    "move",
    "try",
    "unsafe",
};

const define_ends: []const []const u8 = &.{ "->", ";", "where" };
const else_margin: u32 = 7;
const enum_words: []const []const u8 = &.{"enum"};
const extend_bytes: []const u8 = "()]}?>";
const float_suffixes: []const []const u8 = &.{ "f128", "f16", "f32", "f64" };
const fn_braced_reserve: u32 = 3;
const fn_reserve: u32 = 1;
const header_payload_max: u32 = 64;
const hug_heads: []const []const u8 = &.{ "async", "const", "gen", "move", "try", "unsafe" };
const hug_prefixes: []const []const u8 = &.{ "!", "&", "&&", "*", "-", "move", "mut" };
const import_tail_max: u32 = 4;

const integer_suffixes: []const []const u8 = &.{
    "i128",
    "i16",
    "i32",
    "i64",
    "i8",
    "isize",
    "u128",
    "u16",
    "u32",
    "u64",
    "u8",
    "usize",
};

const lambda_heads: []const []const u8 = &.{ "|", "move" };
const lambda_leads: []const []const u8 = &.{ "|", "||", "move" };
const lambda_prefix_max: u32 = 4;
const lambda_prefixes: []const []const u8 = &.{ "!", "&", "*", "-", "mut" };
const lambda_short_max: u32 = 10;
const literal_words: []const []const u8 = &.{ "false", "true" };

const logic_stops: []const []const u8 = &.{
    ",",
    ";",
    "=",
    "=>",
    "break",
    "if",
    "in",
    "let",
    "match",
    "return",
    "while",
};

const macro_arms: []const []const u8 = &.{"match"};
const macro_level_max: u32 = 63;
const nested_types: []const []const u8 = &.{ "<", "::", ",", "&", "(", "[" };
const operand_unaries: []const []const u8 = &.{ "!", "&", "&&", "*", "mut" };
const probe_kind_count: u32 = @typeInfo(ProbeKind).@"enum".field_names.len;
const receive_marks: []const []const u8 = &.{ "!", "$", ".", "::", "?", "?." };
const receive_words: []const []const u8 = &.{ "Self", "await", "crate", "self", "super", "this" };
const comment_stops: []const []const u8 = &.{ "=", ":", "return" };
const sole_prefixes: []const []const u8 = &.{ "!", "&", "&&", "*", "-", "mut" };

const stream_prefixes: []const []const u8 = &.{
    "!=",
    "%",
    "%=",
    "&=",
    "*=",
    "+",
    "+=",
    "-=",
    "/",
    "/=",
    "<<=",
    "<=",
    "=",
    "==",
    ">",
    ">=",
    ">>",
    ">>=",
    "^",
    "^=",
    "|=",
    "~",
};

const stream_stops: []const []const u8 = &.{ ":", "=>", "@" };
const return_room: u32 = 1;
const return_words: []const []const u8 = &.{ "break", "return" };
const switch_words: []const []const u8 = &.{"switch"};
const tuple_words: []const []const u8 = &.{ "enum", "struct", "union" };
const unary_walk_max: u32 = 4;
pub const unwrap_marks: []const []const u8 = &.{ ".*", ".?" };
const variant_scan_max: u32 = 2048;

pub fn forced(emitter: *const Emitter, position: u32, prior: u32) bool {
    assert(position < emitter.count);
    assert(prior < emitter.count);

    if (branches(emitter, position, prior)) return true;
    if (defines(emitter, position, prior)) return true;
    if (uses(emitter, position, prior)) return true;
    if (let_elses(emitter, position, prior)) return true;
    if (attributes(emitter, position, prior)) return true;
    if (braces_a_header(emitter, position)) return true;
    if (header_wided(emitter, position)) return true;
    if (calls(emitter, position, prior)) return true;
    if (impl_parted(emitter, position, prior)) return true;
    if (chains_wide(emitter, position)) return true;
    if (members(emitter, position, prior)) return true;
    if (literals(emitter, position, prior)) return true;
    if (blocks(emitter, position, prior)) return true;
    if (else_parted(emitter, position)) return true;
    return rowed(emitter, prior);
}

fn branches(emitter: *const Emitter, position: u32, prior: u32) bool {
    assert(position < emitter.count);
    assert(prior < emitter.count);

    if (emitter.policy.branch_width == 0) return false;
    if (emitter.tokens[prior].kind == .block_start) return branched(emitter, prior);
    if (emitter.tokens[position].kind != .block_end) return false;

    const open = emit.opened(emitter, position) orelse return false;

    assert(open < position);

    return branched(emitter, open);
}

fn defines(emitter: *const Emitter, position: u32, prior: u32) bool {
    assert(position < emitter.count);
    assert(prior < emitter.count);

    if (!emitter.policy.macro_bodies) return false;

    assert(emitter.depth <= brace.nest_depth_max);

    for (emitter.nest[0..emitter.depth]) |frame| {
        if (frame.kind != .block_start) continue;

        const inner = emit.defined_body(emitter, frame.open) orelse continue;
        const close = emit.closing(emitter, inner) orelse continue;

        assert(inner == frame.open);

        if (emit.ahead_of(emitter, inner) == close) continue;
        if (prior == inner) return true;
        if (close == position) return true;
    }

    return false;
}

fn uses(emitter: *const Emitter, position: u32, prior: u32) bool {
    assert(position < emitter.count);
    assert(prior < emitter.count);

    if (emitter.policy.list_width == 0) return false;

    const open = braced_open(emitter, position, prior) orelse return false;
    const close = join.closing_of(emitter, open) orelse return false;
    const from = emitter.tokens[open].end();
    const to = emitter.tokens[close].offset;
    if (body.parted_by(emitter, from, to) > 0) return false;
    return used(emitter, open);
}

fn braced_open(emitter: *const Emitter, position: u32, prior: u32) ?u32 {
    assert(position < emitter.count);
    assert(prior < emitter.count);

    if (emitter.tokens[prior].kind == .block_start) return prior;
    if (emitter.tokens[position].kind != .block_end) return null;
    return emit.opened(emitter, position);
}

pub fn used(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (emitter.policy.list_width == 0) return false;
    return wide_list(emitter, open, emitter.policy.list_width);
}

pub fn import(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const lead = emit.word_before(emitter, open);
    const grouped = if (lead) |held| text_is(emitter, held, ",") else false;
    const commented = emitter.policy.chain_simples and import_commented(emitter, open);

    if (!grouped) {
        if (!commented) return false;
    }

    return wide_list(emitter, open, emitter.options.line_width);
}

fn import_commented(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.policy.chain_simples);

    const close = join.closing_of(emitter, open) orelse return false;
    var scan = open;

    while (scan < close) : (scan += 1) {
        if (emitter.tokens[scan].kind == .comment) return true;
    }

    return false;
}

fn wide_list(emitter: *const Emitter, open: u32, room: u32) bool {
    assert(open < emitter.count);
    assert(room > 0);

    if (emitter.tokens[open].kind != .block_start) return false;

    const lead = emit.word_before(emitter, open);
    const led = if (lead) |held| line.word_is(emitter, held, emitter.policy.list_leads) else false;
    const head = statement_word(emitter, open) orelse return false;

    if (!led) return false;
    if (!line.word_is(emitter, head, emitter.policy.list_words)) return false;

    const close = join.closing_of(emitter, open) orelse return false;
    if (emit.ahead_of(emitter, open) == close) return false;

    const under = emitter.printed * emitter.options.indent_width;
    return under + used_columns(emitter, head, open, close) > room;
}

fn used_columns(emitter: *const Emitter, head: u32, open: u32, close: u32) u32 {
    assert(head < close);
    assert(open < close);

    const end = statement_close(emitter, close);
    const hugs = emitter.policy.list_hugs;
    var prior: ?u32 = null;
    var scan = head;
    var spelled: u32 = 0;

    while (scan <= end) : (scan += 1) {
        if (scan >= emitter.count) break;

        const token = emitter.tokens[scan];

        if (used_dropped(emitter, scan, close)) continue;

        const apart = if (prior) |before| emitter.tokens[before].end() < token.offset else false;
        const edged = prior == open or scan == close;
        const gapped = apart and (!hugs or !edged);

        spelled += @intFromBool(gapped) + walk.columns(emitter.source, token.offset, token.end());
        prior = scan;
    }

    return spelled;
}

fn used_dropped(emitter: *const Emitter, scan: u32, close: u32) bool {
    assert(scan < emitter.count);
    assert(close < emitter.count);

    const token = emitter.tokens[scan];
    if (token.length == 0) return true;
    if (token.kind == .newline) return true;
    if (!token.is_punctuation(.comma)) return false;
    return emit.ahead_of(emitter, scan) == close;
}

fn let_elses(emitter: *const Emitter, position: u32, prior: u32) bool {
    assert(position < emitter.count);
    assert(prior < emitter.count);

    if (emitter.policy.else_width == 0) return false;

    const open = braced_open(emitter, position, prior) orelse return false;
    return else_wide(emitter, open);
}

fn attributes(emitter: *const Emitter, position: u32, prior: u32) bool {
    assert(position < emitter.count);
    assert(prior < emitter.count);

    if (emitter.policy.attribute_width == 0) return false;

    const separated = emitter.tokens[prior].is_punctuation(.comma);

    assert(emitter.depth <= brace.nest_depth_max);

    for (emitter.nest[0..emitter.depth]) |frame| {
        if (!frame.kind.eql(.{ .punctuation = .paren_open })) continue;

        const open = attribute_parted(emitter, frame.open) orelse continue;
        if (prior == open) return true;
        if (join.closing_of(emitter, open) == position) return true;

        const current = separated and line.frame(emitter).open == open;
        if (current) return true;
    }

    return false;
}

fn attribute_parted(emitter: *const Emitter, held: u32) ?u32 {
    assert(held < emitter.count);
    assert(emitter.policy.attribute_width > 0);

    const bracket = attribute_head(emitter) orelse return null;
    const word = emit.ahead_of(emitter, bracket) orelse return null;
    if (line.word_is(emitter, word, emitter.policy.attribute_words)) return null;

    const open = sole_call(emitter, held);
    const close = join.closing_of(emitter, open) orelse return null;
    if (!metaed(emitter, open, close)) return null;

    const from = emitter.tokens[open].end();
    const to = emitter.tokens[close].offset;
    if (body.parted_by(emitter, from, to) > 0) return null;
    if (walk.columns(emitter.source, from, to) <= emitter.policy.attribute_width) return null;
    return open;
}

fn metaed(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    var depth: u32 = 0;
    var elements: u32 = 1;
    var scan = open + 1;

    while (scan < close) : (scan += 1) {
        const token = emitter.tokens[scan];
        const kind = token.kind;
        const opens = walk.is_open(kind) or kind == .block_start;
        const closes = walk.is_close(kind) or kind == .block_end;
        const comma = depth == 0 and token.is_punctuation(.comma);
        const separated = comma and emit.ahead_of(emitter, scan) != close;

        if (kind == .comment) return false;

        if (opens) depth += 1;
        if (closes) depth -|= 1;
        if (separated) elements += 1;

        if (text_is(emitter, scan, "=")) {
            if (!literal_after(emitter, scan)) return false;
        }
    }

    return elements > 1;
}

fn literal_after(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const held = emit.ahead_of(emitter, position) orelse return false;
    const kind = emitter.tokens[held].kind;
    const valued = kind == .number or kind == .string;
    const literal_token = valued or line.word_is(emitter, held, literal_words);
    if (!literal_token) return false;

    const after = emit.ahead_of(emitter, held) orelse return true;
    const token = emitter.tokens[after];
    if (token.is_punctuation(.comma)) return true;
    return token.is_punctuation(.paren_close);
}

pub fn meta_literal(kind: Token.Kind, text: []const u8) bool {
    assert(kind == .number or kind == .string);
    assert(text.len > 0);

    if (kind == .string) return std.mem.findScalar(u8, "\"#'", text[text.len - 1]) != null;

    const base = number_base(text);
    const start: usize = if (base == 10) 0 else 2;
    const digits_end = digits_scan(text, start, base);
    const digits = text[start..digits_end];
    if (std.mem.findNone(u8, digits, "_") == null) return false;

    var end = digits_end;
    var float = false;

    if (fraction_opens(text, end)) {
        float = true;
        end += 1;

        if (end < text.len) {
            if (std.ascii.isDigit(text[end])) {
                end = digits_scan(text, end, 10);

                if (exponent_opens(text, end)) end = exponent_end(text, end) orelse return false;
            }
        }
    } else if (exponent_opens(text, end)) {
        float = true;
        end = exponent_end(text, end) orelse return false;
    } else {}

    const suffix = text[end..];
    if (float) return base == 10 and (suffix.len == 0 or word_in(float_suffixes, suffix));
    if (suffix.len == 0) return number_fits(digits, base);
    if (word_in(integer_suffixes, suffix)) return number_fits(digits, base);
    return base == 10 and word_in(float_suffixes, suffix);
}

fn number_base(text: []const u8) u8 {
    assert(text.len > 0);

    if (text.len < 2) return 10;
    if (text[0] != '0') return 10;

    return switch (text[1]) {
        'b' => 2,
        'o' => 8,
        'x' => 16,
        else => 10,
    };
}

fn digits_scan(text: []const u8, start: usize, base: u8) usize {
    assert(start <= text.len);
    assert(base == 2 or base == 8 or base == 10 or base == 16);

    var end = start;

    while (end < text.len) : (end += 1) {
        const byte = text[end];
        const digit = if (base == 16) std.ascii.isHex(byte) else std.ascii.isDigit(byte);

        if (!digit) {
            if (byte != '_') break;
        }
    }

    assert(end >= start);

    return end;
}

fn fraction_opens(text: []const u8, end: usize) bool {
    assert(end <= text.len);

    if (end == text.len) return false;
    if (text[end] != '.') return false;
    if (end + 1 == text.len) return true;

    const byte = text[end + 1];
    const identifier = std.ascii.isAlphabetic(byte) or byte == '_' or byte >= 0x80;

    return byte != '.' and !identifier;
}

fn exponent_opens(text: []const u8, end: usize) bool {
    assert(end <= text.len);

    if (end == text.len) return false;
    return text[end] == 'e' or text[end] == 'E';
}

fn exponent_end(text: []const u8, end: usize) ?usize {
    assert(exponent_opens(text, end));

    var start = end + 1;

    if (start < text.len) {
        const signed = text[start] == '+' or text[start] == '-';

        if (signed) start += 1;
    }

    const stop = digits_scan(text, start, 10);
    if (std.mem.findNone(u8, text[start..stop], "_") == null) return null;
    return stop;
}

fn number_fits(digits: []const u8, base: u8) bool {
    assert(digits.len > 0);
    assert(base == 2 or base == 8 or base == 10 or base == 16);

    var value: u128 = 0;

    for (digits) |byte| {
        if (byte == '_') continue;

        const digit = std.fmt.charToDigit(byte, base) catch return false;
        const product = @mulWithOverflow(value, base);
        if (product[1] != 0) return false;

        const sum = @addWithOverflow(product[0], digit);
        if (sum[1] != 0) return false;

        value = sum[0];
    }

    return true;
}

fn braces_a_header(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.levels <= core.line_level_max);

    const braced = emitter.tokens[position].kind == .block_start or
        payload.block_labeled(emitter, position);

    if (!emitter.policy.header_braces) return false;
    if (!braced) return false;

    if (!emitter.policy.header_levels) {
        if (emitter.printed <= emitter.levels) return false;
    }

    const held = emit.back_of(emitter, position) orelse return false;
    const closed = emitter.tokens[held].is_punctuation(.paren_close);

    if (!closed) {
        if (!line.word_is(emitter, held, emitter.policy.source_words)) return false;
    }

    if (closed) {
        if (braces_a_header_switched(emitter, held)) return false;
    }

    const head = line.head_word(emitter, position, emitter.policy.header_words) orelse return false;
    var scan = head;

    while (scan < position) : (scan += 1) {
        const kind = emitter.tokens[scan].kind;
        if (kind == .block_end) return false;
        if (kind == .block_start) return false;
        if (line.word_is(emitter, scan, emitter.policy.level_words)) return false;
    }

    if (emitter.policy.header_levels) {
        if (!braces_a_header_prefixed(emitter, head, held)) return false;
        if (!braces_a_header_indented(emitter, head)) return false;
    }

    if (emitter.policy.header_extends) {
        if (extendable(emitter, position)) return false;
    }

    return emitter.line_first > head;
}

fn braces_a_header_indented(emitter: *const Emitter, head: u32) bool {
    assert(head < emitter.count);
    assert(emitter.policy.header_levels);

    const seat = line.level_at(emitter, head) orelse return false;
    return emitter.printed > seat;
}

fn braces_a_header_prefixed(emitter: *const Emitter, head: u32, held: u32) bool {
    assert(head < held);
    assert(emitter.policy.header_levels);

    if (header_prefix_ends(emitter, head, held)) return true;
    if (!emitter.tokens[held].is_punctuation(.paren_close)) return false;

    const open = emitter.brackets.open_of(held) orelse return false;
    const colon = emit.back_of(emitter, open) orelse return false;
    if (!emitter.tokens[colon].is_punctuation(.colon)) return false;

    const prior = emit.back_of(emitter, colon) orelse return false;
    if (prior <= head) return false;
    return header_prefix_ends(emitter, head, prior);
}

fn header_prefix_ends(emitter: *const Emitter, head: u32, held: u32) bool {
    assert(head < held);
    assert(held < emitter.count);

    var close = held;

    if (line.word_is(emitter, held, emitter.policy.source_words)) {
        close = header_payload_opened(emitter, head, held) orelse return false;
    }

    if (!emitter.tokens[close].is_punctuation(.paren_close)) return false;

    const open = emitter.brackets.open_of(close) orelse return false;

    assert(open < close);

    return emit.back_of(emitter, open) == head;
}

fn header_payload_opened(emitter: *const Emitter, head: u32, bar: u32) ?u32 {
    assert(head < bar);
    assert(line.word_is(emitter, bar, emitter.policy.source_words));

    var scan = bar;

    for (0..header_payload_max) |_| {
        const held = emit.back_of(emitter, scan) orelse return null;
        const barred = line.word_is(emitter, held, emitter.policy.source_words);

        assert(held < scan);

        if (held <= head) return null;
        if (barred) return emit.back_of(emitter, held);

        scan = held;
    }

    return null;
}

fn extendable(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var scan = emitter.line_first;

    while (scan < position) : (scan += 1) {
        const bytes = emitter.tokens[scan].text(emitter.source);

        for (bytes) |byte| {
            if (std.mem.findScalar(u8, extend_bytes, byte) == null) return false;
        }
    }

    return true;
}

fn braces_a_header_switched(emitter: *const Emitter, close: u32) bool {
    assert(close < emitter.count);
    assert(emitter.tokens[close].is_punctuation(.paren_close));

    const open = emitter.brackets.open_of(close) orelse return false;

    assert(open < close);

    const word = emit.back_of(emitter, open) orelse return false;
    return line.word_is(emitter, word, switch_words);
}

fn header_wided(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.header_widths) return false;
    if (emitter.tokens[position].kind != .block_start) return false;

    const head = line.head_word(emitter, position, emitter.policy.header_words) orelse return false;
    if (emitter.line_first > head) return false;

    var scan = head;

    while (scan < position) : (scan += 1) {
        const kind = emitter.tokens[scan].kind;
        if (kind == .block_end) return false;
        if (kind == .block_start) return false;
    }

    const width = join.header_width(emitter, head, position) orelse return false;
    return emitter.printed * emitter.options.indent_width + width > emitter.options.line_width;
}

pub fn calls(emitter: *const Emitter, position: u32, prior: u32) bool {
    assert(position < emitter.count);
    assert(prior < emitter.count);

    if (emitter.policy.call_width == 0) return false;
    if (attribute_head(emitter) != null) return false;

    const comma_prior = emitter.tokens[prior].is_punctuation(.comma);

    const separated = comma_prior and join.angle_head(emitter, prior) == null and
        !closure.barred(emitter, prior);

    var reached_open: u32 = 0;
    var reached_close: u32 = 0;

    assert(emitter.depth <= brace.nest_depth_max);

    for (emitter.nest[0..emitter.depth]) |*frame| {
        const inside = frame.open > reached_open and frame.open <= reached_close;
        if (inside) continue;
        if (!calls_framed(emitter, frame)) continue;
        if (returned_list(emitter, frame.open)) continue;

        const open = listed(emitter, frame.open) orelse continue;
        const overflowed = emitter.policy.call_budgets and open > frame.open;

        if (overflowed) {
            reached_open = frame.open;
            reached_close = open;
        }

        if (prior == open) return true;

        if (!calls_hugged(emitter, open, overflowed)) {
            if (join.closing_of(emitter, open) == position) return true;
        }

        if (!separated) continue;
        if (calls_separated(emitter, frame.open, open, prior)) |broken| return broken;
    }

    return false;
}

fn returned_list(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    if (emitter.policy.define_words.len == 0) return false;

    var depth: u32 = 0;
    var scan = open;

    for (0..core.type_scan_max) |_| {
        const held = emit.back_of(emitter, scan) orelse return false;
        const token = emitter.tokens[held];

        assert(held < scan);

        if (token.kind == .block_start) return false;
        if (token.kind == .block_end) return false;

        if (walk.is_close(token.kind)) {
            depth += 1;
        } else if (walk.is_open(token.kind)) {
            if (depth == 0) return false;

            depth -= 1;
        } else if (depth == 0) {
            if (separating(emitter, held)) return false;
            if (text_is(emitter, held, "->")) return returned_params(emitter, held);
        } else {}

        scan = held;
    }

    return false;
}

fn returned_params(emitter: *const Emitter, arrow: u32) bool {
    assert(arrow < emitter.count);

    const close = emit.back_of(emitter, arrow) orelse return false;
    if (!emitter.tokens[close].is_punctuation(.paren_close)) return false;

    const open = emitter.brackets.open_of(close) orelse return false;
    const head = join.body_signature(emitter, close) orelse return false;
    if (head >= open) return false;
    if (!header.arrow_params(emitter, head, open)) return false;
    return head >= emitter.line_first;
}

fn calls_framed(emitter: *const Emitter, frame: *const core.Frame) bool {
    assert(frame.open < emitter.count);
    assert(emitter.depth > 0);

    if (frame.kind.eql(.{ .punctuation = .paren_open })) return true;

    if (join.closing_of(emitter, frame.open)) |close| {
        if (macroed(emitter, frame.open, close)) return true;
    }

    return frame.kind.eql(.{ .punctuation = .bracket_open });
}

fn calls_hugged(emitter: *const Emitter, open: u32, overflowed: bool) bool {
    assert(open < emitter.count);

    if (overflowed) assert(emitter.policy.call_budgets);

    if (overflowed) {
        if (calls_hugged_end(emitter, open)) return true;
    }

    return hugged_call(emitter, open);
}

fn calls_hugged_end(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const end = join.closing_of(emitter, open) orelse return false;

    assert(end > open);

    if (elemental_list(emitter, open, end)) return false;

    const tail = emit.back_of(emitter, end) orelse return false;
    return emitter.tokens[tail].kind == .block_end;
}

fn calls_separated(emitter: *const Emitter, outer: u32, open: u32, prior: u32) ?bool {
    assert(outer <= open);
    assert(prior < emitter.count);

    if (line.frame(emitter).open != open) return null;
    if (lambda_barred(emitter, open, prior)) return null;
    if (filled_list(emitter, outer)) return null;
    return macro_broken(emitter, open, prior);
}

fn lambda_barred(emitter: *const Emitter, open: u32, position: u32) bool {
    assert(open < emitter.count);
    assert(position < emitter.count);

    var depth: u32 = 0;
    var lambda = false;
    var prior: ?u32 = null;
    var scan = open + 1;

    while (scan < position) : (scan += 1) {
        const token = emitter.tokens[scan];
        const opens = operand_opens(emitter, prior);
        const barring = depth == 0 and text_is(emitter, scan, "|");
        const toggles = barring and (lambda or opens);

        if (toggles) {
            lambda = !lambda;
        } else if (walk.is_open(token.kind)) {
            depth += 1;
        } else if (walk.is_close(token.kind)) {
            depth -|= 1;
        } else {}

        if (token.length > 0) prior = scan;
    }

    return lambda;
}

fn filled_list(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const close = join.closing_of(emitter, open) orelse return false;

    if (macro_grouped(emitter, open)) return false;
    if (!simple_elements(emitter, open, close, 0, std.math.maxInt(u32))) return false;
    if (!reach.short_elements(emitter.tokens, open, close)) return false;

    const from = emitter.tokens[open].end();
    const to = emitter.tokens[close].offset;
    const under = (emitter.printed + 1) * emitter.options.indent_width;

    return under + walk.columns(emitter.source, from, to) <= emitter.options.line_width;
}

fn macro_broken(emitter: *const Emitter, open: u32, prior: u32) bool {
    assert(open < emitter.count);
    assert(prior < emitter.count);

    const close = join.closing_of(emitter, open) orelse return true;
    const bang = emit.word_before(emitter, open) orelse return true;
    if (!emitter.tokens[bang].is_punctuation(.bang)) return true;

    const name = emit.word_before(emitter, bang) orelse return true;
    const group = macro_group(emitter, name) orelse return macro_broken_plain(emitter, open, close);
    const elements = element_count(emitter, open, close);
    if (elements <= group) return true;
    if (!simple_elements(emitter, open, close, 0, group)) return true;
    if (!simple_elements(emitter, open, close, group + 1, std.math.maxInt(u32))) return true;
    return element_index(emitter, open, prior) <= group;
}

fn macro_broken_plain(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    if (!simple_elements(emitter, open, close, 0, std.math.maxInt(u32))) return true;
    return !reach.short_elements(emitter.tokens, open, close);
}

fn macro_grouped(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    if (!emitter.policy.call_budgets) return false;

    const bang = emit.word_before(emitter, open) orelse return false;
    if (!emitter.tokens[bang].is_punctuation(.bang)) return false;

    const name = emit.word_before(emitter, bang) orelse return false;
    return macro_group(emitter, name) != null;
}

fn macro_group(emitter: *const Emitter, name: u32) ?u32 {
    assert(name < emitter.count);
    assert(core.macro_groups.len > 0);

    const bytes = emitter.tokens[name].text(emitter.source);

    for (core.macro_groups) |entry| {
        const word, const group = entry;
        if (walk.text_eql(bytes, word)) return group;
    }

    return null;
}

fn element_index(emitter: *const Emitter, open: u32, position: u32) u32 {
    assert(open < emitter.count);
    assert(position < emitter.count);

    var depth: u32 = 0;
    var index: u32 = 0;
    var scan = open + 1;

    while (scan < position) : (scan += 1) {
        const kind = emitter.tokens[scan].kind;
        const opens = walk.is_open(kind) or kind == .block_start;
        const closes = walk.is_close(kind) or kind == .block_end;

        if (opens) {
            depth += 1;
        } else if (closes) {
            depth -|= 1;
        } else if (depth == 0) {
            if (kind.eql(.{ .punctuation = .comma })) index += 1;
        } else {}
    }

    assert(index <= position -| open);

    return index;
}

fn simple_elements(emitter: *const Emitter, open: u32, close: u32, first: u32, last: u32) bool {
    assert(open < close);
    assert(first <= last);

    var depth: u32 = 0;
    var index: u32 = 0;
    var scan = open + 1;

    while (scan < close) : (scan += 1) {
        const token = emitter.tokens[scan];
        const kind = token.kind;
        const separated = depth == 0 and kind.eql(.{ .punctuation = .comma });
        const ranged = index >= first and index < last;
        const opens = walk.is_open(kind) or kind == .block_start;
        const closes = walk.is_close(kind) or kind == .block_end;

        if (separated) {
            index += 1;
        } else if (ranged) {
            if (!walk.simple_word(token, emitter.source)) return false;
        } else {}

        if (opens) {
            depth += 1;
        } else if (closes) {
            depth -|= 1;
        } else {}
    }

    return true;
}

fn chains_wide(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    const head = chains_head(emitter, position) orelse return false;

    assert(head <= position);

    if (braced_line(emitter, head)) return false;
    return probed(emitter, probe_of(.chained_over, head, position));
}

pub fn chains_head(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (emitter.policy.chain_width == 0) return null;
    if (!dotted(emitter, position)) return null;

    const head = chain_head(emitter, position);

    assert(head <= position);

    return head;
}

fn members(emitter: *const Emitter, position: u32, prior: u32) bool {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.policy.field_width == 0) return false;

    const held = emit.back_of(emitter, position);
    const separated = if (held) |found| emitter.tokens[found].is_punctuation(.semicolon) else false;

    for (emitter.nest[0..emitter.depth]) |frame| {
        if (frame.kind != .block_start) continue;
        if (!split.fields_wide(emitter, frame.open)) continue;
        if (prior == frame.open) return true;
        if (emit.closing(emitter, frame.open) == position) return true;

        const current = separated and line.frame(emitter).open == frame.open;
        if (current) return true;
    }

    return false;
}

pub fn literals(emitter: *const Emitter, position: u32, prior: u32) bool {
    assert(position < emitter.count);
    assert(prior < emitter.count);

    if (emitter.policy.literal_width == 0) return false;

    const comma_prior = emitter.tokens[prior].is_punctuation(.comma);

    const separated = comma_prior and join.angle_head(emitter, prior) == null and
        !closure.barred(emitter, prior);

    assert(emitter.depth <= brace.nest_depth_max);

    for (emitter.nest[0..emitter.depth]) |frame| {
        if (frame.kind != .block_start) continue;
        if (!literal(emitter, frame.open)) continue;
        if (prior == frame.open) return true;
        if (emit.closing(emitter, frame.open) == position) return true;

        const current = separated and line.frame(emitter).open == frame.open;
        if (current) return true;
    }

    return false;
}

fn blocks(emitter: *const Emitter, position: u32, prior: u32) bool {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    for (emitter.nest[0..emitter.depth]) |frame| {
        if (frame.kind != .block_start) continue;
        if (emit.welded_body(emitter, frame.open)) continue;
        if (!block(emitter, frame.open)) continue;
        if (prior == frame.open) return true;
        if (emit.closing(emitter, frame.open) == position) return true;
    }

    return false;
}

pub fn block(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    return probed(emitter, probe_of(.block, open, 0));
}

fn probed(emitter: *const Emitter, root: Probe) bool {
    assert(root.stage == 0);
    assert(root.open < emitter.count);
    assert(root.point < emitter.count);
    assert(root.scan == 0);
    assert(!root.admitted);
    assert(!root.over);

    const keyed = @as(u64, root.point) * probe_kind_count + @backingInt(root.kind);
    const argument = std.math.cast(u32, keyed) orelse return probed_scanned(emitter, root);
    if (core.memo_found(emitter, .probed, root.open, argument)) |answer| return answer == 1;

    const held = probed_scanned(emitter, root);

    core.memo_store(emitter, .probed, root.open, argument, @intFromBool(held));

    return held;
}

fn probed_scanned(emitter: *const Emitter, root: Probe) bool {
    assert(root.stage == 0);
    assert(root.open < emitter.count);

    return join.verdict_of(join.evaluated(emitter, .{ .probe = root }));
}

pub fn probe_of(kind: ProbeKind, open: u32, point: u32) Probe {
    if (kind == .chained_line) assert(open < point);
    if (kind == .chained_over) assert(open <= point);

    return .{
        .admitted = false,
        .kind = kind,
        .open = open,
        .over = false,
        .point = point,
        .scan = 0,
        .stage = 0,
    };
}

pub fn probe_step(emitter: *const Emitter, probe: *Probe, answer: ?bool) join.Step {
    assert(probe.open < emitter.count);
    assert((answer != null) == (probe.stage > 0));

    return switch (probe.kind) {
        .block => block_step(emitter, probe, answer),
        .braced_line => braced_line_step(emitter, probe, answer),
        .branched => branched_step(emitter, probe, answer),
        .chained_line => chained_line_step(emitter, probe, answer),
        .chained_over => chained_over_step(emitter, probe, answer),
        .literal => literal_step(emitter, probe, answer),
        .root_lined => root_lined_step(emitter, probe, answer),
    };
}

fn block_step(emitter: *const Emitter, probe: *Probe, answer: ?bool) join.Step {
    assert(probe.kind == .block);
    assert(probe.point == 0);
    if (probe.stage == 0) assert(answer == null);

    if (answer) |lined| {
        if (lined) return .{ .done = true };
        return .{ .done = block_rest(emitter, probe.open, probe.scan) };
    }

    const close = block_close(emitter, probe.open) orelse return .{ .done = false };

    probe.scan = close;
    probe.stage = 1;

    return .{ .call = .{ .probe = probe_of(.chained_line, probe.open, close) } };
}

fn block_close(emitter: *const Emitter, open: u32) ?u32 {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (emitter.policy.literal_width == 0) return null;
    if (emitter.tokens[open].kind != .block_start) return null;
    if (valued_brace(emitter, open)) return null;
    if (emitter.brackets.angles_at(open) > 0) return null;

    const close = join.closing_of(emitter, open) orelse return null;
    const from = emitter.tokens[open].end();
    const to = emitter.tokens[close].offset;

    assert(open < close);

    if (body.parted_by(emitter, from, to) > 0) return null;
    if (commented_value(emitter, open)) return null;
    return close;
}

fn block_rest(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    if (branched_line(emitter, open, close)) return true;
    if (hugged_over(emitter, open, close)) return true;

    var scan = open + 1;

    while (scan < close) : (scan += 1) {
        if (spans_wide(emitter, scan)) return true;
    }

    return false;
}

fn braced_line_step(emitter: *const Emitter, probe: *Probe, answer: ?bool) join.Step {
    assert(probe.kind == .braced_line);
    assert(probe.stage <= 3);
    if (probe.stage == 0) assert(answer == null);

    const found = answer orelse return braced_line_start(emitter, probe);

    assert(probe.scan < probe.open);

    if (probe.stage == 3) return .{ .done = !found };
    if (found) return .{ .done = false };

    probe.stage += 1;

    const kind: ProbeKind = if (probe.stage == 2) .branched else .block;
    return .{ .call = .{ .probe = probe_of(kind, probe.scan, 0) } };
}

fn braced_line_start(emitter: *const Emitter, probe: *Probe) join.Step {
    assert(probe.kind == .braced_line);
    assert(probe.stage == 0);

    const head = braced_head(emitter, probe.open) orelse return .{ .done = false };
    if (split.fields_wide(emitter, head)) return .{ .done = false };

    probe.scan = head;
    probe.stage = 1;

    return .{ .call = .{ .probe = probe_of(.literal, head, 0) } };
}

fn literal_step(emitter: *const Emitter, probe: *Probe, answer: ?bool) join.Step {
    assert(probe.kind == .literal);
    assert(probe.point == 0);
    if (probe.stage == 0) assert(answer == null);

    if (answer) |braced| {
        if (braced) return .{ .done = false };
        return .{ .done = literal_tail(emitter, probe.open) };
    }

    if (!valued_brace(emitter, probe.open)) return .{ .done = false };

    probe.stage = 1;

    return .{ .call = .{ .probe = probe_of(.braced_line, probe.open, 0) } };
}

fn branched_step(emitter: *const Emitter, probe: *Probe, answer: ?bool) join.Step {
    assert(probe.kind == .branched);
    assert(probe.point == 0);
    if (probe.stage == 0) assert(answer == null);

    if (answer) |braced| {
        if (braced) return .{ .done = false };
        if (commented_value(emitter, probe.scan)) return .{ .done = false };
        return .{ .done = branched_over(emitter, probe.scan) };
    }

    const head = branch_head(emitter, probe.open) orelse return .{ .done = false };

    assert(head < probe.open);

    probe.scan = head;
    probe.stage = 1;

    return .{ .call = .{ .probe = probe_of(.braced_line, head, 0) } };
}

fn chained_line_step(emitter: *const Emitter, probe: *Probe, answer: ?bool) join.Step {
    assert(probe.kind == .chained_line);
    assert(probe.open < probe.point);
    if (probe.stage == 0) assert(answer == null);

    if (answer) |chained| {
        if (chained) return .{ .done = true };

        probe.scan += 1;
    } else {
        if (emitter.policy.chain_width == 0) return .{ .done = false };
        if (!emitter.policy.block_chains) return .{ .done = false };

        probe.scan = probe.open + 1;
    }

    return chained_line_scan(emitter, probe);
}

fn chained_line_scan(emitter: *const Emitter, probe: *Probe) join.Step {
    assert(probe.kind == .chained_line);
    assert(probe.scan > probe.open);

    while (probe.scan < probe.point) : (probe.scan += 1) {
        if (!dotted(emitter, probe.scan)) continue;

        const head = chain_head(emitter, probe.scan);
        if (head <= probe.open) continue;

        probe.stage = 1;

        return .{ .call = .{ .probe = probe_of(.chained_over, head, probe.scan) } };
    }

    return .{ .done = false };
}

fn chained_over_step(emitter: *const Emitter, probe: *Probe, answer: ?bool) join.Step {
    assert(probe.kind == .chained_over);
    assert(probe.open <= probe.point);
    if (probe.stage == 0) assert(answer == null);

    if (answer) |lined| {
        if (probe.stage == 2) return chained_over_rooted(emitter, probe, lined);
        return .{ .done = probe.admitted and (lined or probe.over) };
    }

    const head = probe.open;
    const position = probe.point;

    if (commented_value(emitter, head)) return .{ .done = false };

    const end, const links, const parent = chain_end(emitter, head);

    if (links == 0) return .{ .done = false };
    if (position <= parent) return .{ .done = false };

    if (parent == head) {
        switch (rooting(emitter, head, position)) {
            .back => |back| {
                probe.stage = 2;

                return .{ .call = join.flattened_frame(back) };
            },
            .verdict => |held| {
                if (held) return .{ .done = false };
            },
        }
    }

    return chained_over_rest(emitter, probe, end, links);
}

fn chained_over_rooted(emitter: *const Emitter, probe: *Probe, flattened: bool) join.Step {
    assert(probe.kind == .chained_over);
    assert(probe.stage == 2);

    const head = probe.open;

    if (!flattened) {
        if (rooted_block(emitter, head)) return .{ .done = false };
    }

    const end, const links, _ = chain_end(emitter, head);
    return chained_over_rest(emitter, probe, end, links);
}

fn chained_over_rest(emitter: *const Emitter, probe: *Probe, end: u32, links: u32) join.Step {
    assert(probe.kind == .chained_over);
    assert(links > 0);
    assert(end <= emitter.count);

    const head = probe.open;
    const position = probe.point;
    if (rooted_parted(emitter, head, position)) return .{ .done = true };
    if (links >= 2) return .{ .done = chained_over_flat(emitter, head, end) };

    const seat = chained_over_seat(emitter, head, position, end);

    probe.admitted = seat[0];
    probe.over = seat[1];
    probe.stage = 1;

    return .{ .call = .{ .probe = probe_of(.root_lined, head, position) } };
}

fn chained_over_seat(emitter: *const Emitter, head: u32, position: u32, end: u32) struct {
    bool,
    bool,
} {
    assert(head < position);
    assert(end < emitter.count);

    const line_width = emitter.options.line_width;
    const column = chained_seat(emitter, head);
    const root = flat_columns(emitter, head, position);
    const flat = flat_columns(emitter, head, end + 1) + chain_margin(emitter, end);
    const spread = spread_of(emitter, head);
    const indent = emitter.options.indent_width;

    const seated_link = flat_line(emitter, position, end + 1) and
        !linked_braced(emitter, position, end) and
        column + indent + flat_columns(emitter, position, end + 1) <= line_width;

    const from = emitter.tokens[head].offset;
    const to = emitter.tokens[end].end();

    const written = body.parted_by(emitter, from, to) == 0 or
        linked_over(emitter, head, end) or
        seated_link;

    const steady = spread + root <= line_width and spread + flat > line_width;
    const seated = heads_line(emitter, head) or lined_of(emitter, head) <= line_width or steady;
    const admitted = seated and position > head + 1 and written and column + root <= line_width;

    return .{ admitted, column + flat > line_width };
}

fn chained_over_flat(emitter: *const Emitter, head: u32, end: u32) bool {
    assert(head <= end);
    assert(end < emitter.count);

    const column = chained_seat(emitter, head);
    const flat = flat_columns(emitter, head, end + 1);
    const overflowing = column + flat > emitter.options.line_width;
    const point = hug_point(emitter, head, end, overflowing);
    const reached = column + flat_columns(emitter, head, linked_first(emitter, head, end));
    const tries = flat_columns(emitter, head, point) + chain_tries(emitter, head, end);
    const tried = tries > emitter.policy.chain_width;
    const lined = linked_over(emitter, head, end) and tried;

    if (reached > emitter.options.line_width) return false;
    if (lambda_hung(emitter, head)) return true;
    if (lined) return true;
    if (linked_over(emitter, head, end)) return false;
    return tried;
}

fn root_lined_step(emitter: *const Emitter, probe: *Probe, answer: ?bool) join.Step {
    assert(probe.kind == .root_lined);
    assert(probe.open <= probe.point);
    if (probe.stage == 0) assert(answer == null);

    if (answer) |found| {
        if (found) return .{ .done = true };

        if (probe.stage == 1) {
            probe.stage = 2;

            return .{ .call = .{ .probe = probe_of(.block, probe.scan, 0) } };
        }

        probe.scan += 1;
    } else {
        probe.scan = probe.open;
    }

    return root_lined_scan(emitter, probe);
}

fn root_lined_scan(emitter: *const Emitter, probe: *Probe) join.Step {
    assert(probe.kind == .root_lined);
    assert(probe.scan >= probe.open);

    while (probe.scan < probe.point) : (probe.scan += 1) {
        if (emitter.tokens[probe.scan].kind != .block_start) continue;
        if (root_lined_parted(emitter, probe.scan)) return .{ .done = true };

        probe.stage = 1;

        return .{ .call = .{ .probe = probe_of(.literal, probe.scan, 0) } };
    }

    return .{ .done = false };
}

fn root_lined_parted(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.tokens[open].kind == .block_start);

    const close = join.closing_of(emitter, open) orelse return false;
    const from = emitter.tokens[open].end();
    const to = emitter.tokens[close].offset;

    return body.parted_by(emitter, from, to) > 0;
}

pub fn else_joined(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (emitter.policy.else_width == 0) return false;
    if (!text_is(emitter, position, "else")) return false;

    const open = emit.ahead_of(emitter, position) orelse return false;
    if (emitter.tokens[open].kind != .block_start) return false;

    const head = statement_word(emitter, position) orelse return false;
    if (head >= position) return false;
    if (!text_is(emitter, head, "let")) return false;
    if (else_wide(emitter, open)) return false;
    if (emitter.line_first > head) return false;

    const under = (emitter.printed + 1) * emitter.options.indent_width;
    const width = flat_columns(emitter, emitter.line_first, position);

    return emitter.options.line_width -| (under + width) >= else_margin;
}

fn else_parted(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (emitter.policy.else_width == 0) return false;
    if (!text_is(emitter, position, "else")) return false;

    const open = emit.ahead_of(emitter, position) orelse return false;
    if (emitter.tokens[open].kind != .block_start) return false;

    const held = emit.back_of(emitter, position) orelse return false;
    if (emitter.tokens[held].kind == .block_end) return false;

    const head = statement_word(emitter, position) orelse return false;
    if (head >= position) return false;
    if (!text_is(emitter, head, "let")) return false;
    if (emitter.line_first <= head) return false;

    if (else_assign(emitter, head, position)) |assign| {
        if (join.line_lead(emitter, assign)) |lead| {
            if (lead[0] > head) return true;
        }
    }

    if (join.line_lead(emitter, head)) |lead| {
        if (emitter.printed > lead[1]) return true;
    }

    return !walk.is_close(emitter.tokens[held].kind);
}

fn else_assign(emitter: *const Emitter, head: u32, stop: u32) ?u32 {
    assert(head < stop);
    assert(stop < emitter.count);

    var depth: u32 = 0;
    var scan = head;

    for (0..core.define_scan_max) |_| {
        if (scan >= stop) return null;

        const kind = emitter.tokens[scan].kind;
        const opens = walk.is_open(kind) or kind == .block_start;
        const closes = walk.is_close(kind) or kind == .block_end;

        if (opens) {
            depth += 1;
        } else if (closes) {
            depth -|= 1;
        } else if (depth == 0) {
            if (kind.eql(.{ .punctuation = .assign })) return scan;
        } else {}

        scan = emit.ahead_of(emitter, scan) orelse return null;
    }

    return null;
}

fn else_wide(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (emitter.policy.else_width == 0) return false;
    if (emitter.tokens[open].kind != .block_start) return false;

    const held = emit.back_of(emitter, open) orelse return false;
    if (!text_is(emitter, held, "else")) return false;

    const branch = emit.back_of(emitter, held) orelse return false;
    if (emitter.tokens[branch].kind == .block_end) return false;

    const head = statement_word(emitter, held) orelse return false;
    if (!text_is(emitter, head, "let")) return false;
    if (braced_line(emitter, head)) return false;

    const close = emit.closing(emitter, open) orelse return false;
    const end = statement_close(emitter, close);
    const from = emitter.tokens[head].offset;
    const to = emitter.tokens[end].end();
    if (body.parted_by(emitter, from, to) > 0) return false;
    return walk.columns(emitter.source, from, to) > emitter.policy.else_width;
}

fn rowed(emitter: *const Emitter, separator: u32) bool {
    assert(separator < emitter.count);

    if (!emitter.policy.row_parts) return false;
    if (!commas(emitter, separator)) return false;

    const frame = line.frame(emitter);
    if (frame.kind != .block_start) return false;
    if (!initialised(emitter, frame.open)) return false;

    if (emit.ahead_of(emitter, separator)) |held| {
        if (emitter.tokens[held].kind == .comment) return false;
    }

    const tail = emit.back_of(emitter, frame.close) orelse return false;
    const magic = tail != separator and commas(emitter, tail);

    assert(tail < frame.close);

    if (!magic) return false;
    if (element_ahead(emitter, separator)) return true;
    return element_behind(emitter, separator);
}

fn initialised(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    if (emit.bodied(emitter, open)) return false;

    const held = emit.back_of(emitter, open) orelse return false;
    if (emit.is_dot(emitter, held)) return true;
    return valued_brace(emitter, open);
}

fn element_ahead(emitter: *const Emitter, separator: u32) bool {
    assert(separator < emitter.count);
    assert(commas(emitter, separator));

    const stop = line.frame(emitter).close;
    var depth: u32 = 0;
    var scan = separator;

    for (0..core.define_scan_max) |_| {
        const held = emit.ahead_of(emitter, scan) orelse return false;
        const separated = depth == 0 and commas(emitter, held);

        assert(held > scan);

        if (held >= stop) return false;
        if (separated) return false;
        if (split.broke(emitter, scan, held)) return true;

        const kind = emitter.tokens[held].kind;

        if (walk.is_open(kind)) depth += 1;
        if (walk.is_close(kind)) depth -|= 1;

        scan = held;
    }

    return false;
}

fn element_behind(emitter: *const Emitter, separator: u32) bool {
    assert(separator < emitter.count);
    assert(commas(emitter, separator));

    const stop = line.frame(emitter).open;
    var depth: u32 = 0;
    var scan = separator;

    for (0..core.define_scan_max) |_| {
        const held = emit.back_of(emitter, scan) orelse return false;
        const separated = depth == 0 and commas(emitter, held);

        assert(held < scan);

        if (held <= stop) return false;
        if (separated) return false;
        if (emitter.tokens[held].kind == .comment) return false;
        if (split.broke(emitter, held, scan)) return true;

        const kind = emitter.tokens[held].kind;

        if (walk.is_close(kind)) depth += 1;
        if (walk.is_open(kind)) depth -|= 1;

        scan = held;
    }

    return false;
}

fn commas(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    return emitter.tokens[position].is_punctuation(.comma);
}

pub fn attribute_head(emitter: *const Emitter) ?u32 {
    assert(emitter.depth <= brace.nest_depth_max);

    for (emitter.nest[0..emitter.depth]) |frame| {
        if (!frame.kind.eql(.{ .punctuation = .bracket_open })) continue;

        assert(frame.open < emitter.count);

        if (hashed(emitter, frame.open)) return frame.open;
    }

    return null;
}

fn hashed(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    const held = emit.back_of(emitter, open) orelse return false;

    assert(held < open);

    if (text_is(emitter, held, "#")) return true;
    if (text_is(emitter, held, "#!")) return true;
    if (!text_is(emitter, held, "!")) return false;

    const hash = emit.back_of(emitter, held) orelse return false;
    return text_is(emitter, hash, "#");
}

pub fn literal(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    return probed(emitter, probe_of(.literal, open, 0));
}

fn literal_tail(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (commented_value(emitter, open)) return false;
    if (attribute_head(emitter) != null) return false;

    const close = emit.closing(emitter, open) orelse return false;
    const lead = emit.ahead_of(emitter, open) orelse return false;
    if (lead == close) return false;

    const tail = emit.back_of(emitter, close) orelse lead;
    const from = emitter.tokens[lead].offset;
    const to = emitter.tokens[tail].end();
    if (body.parted_by(emitter, from, to) > 0) return false;

    if (varied_brace(emitter, open) != null) {
        if (variant_marked(emitter, open, close)) return true;
    }

    return walk.columns(emitter.source, from, to) > literal_bound(emitter, open);
}

fn literal_bound(emitter: *const Emitter, open: u32) u32 {
    assert(open < emitter.count);

    const curly = varied_brace(emitter, open) orelse return emitter.policy.literal_width;

    assert(curly < open);

    if (variant_parted(emitter, curly)) return 0;
    return emitter.policy.variant_width;
}

pub fn variant_held(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const curly = varied_brace(emitter, open) orelse return false;
    if (variant_parted(emitter, curly)) return true;

    const close = emit.closing(emitter, open) orelse return false;
    const lead = emit.ahead_of(emitter, open) orelse return false;
    if (lead >= close) return false;

    const tail = emit.back_of(emitter, close) orelse lead;
    return flat_columns(emitter, lead, tail + 1) > emitter.policy.variant_width;
}

fn variant_parted(emitter: *const Emitter, curly: u32) bool {
    assert(curly < emitter.count);
    assert(emitter.policy.variant_width > 0);

    const end = join.closing_of(emitter, curly) orelse return false;
    const stop = @min(end, curly + 1 + variant_scan_max);
    var depth: u32 = 0;
    var lined = false;
    var parted = false;
    var start = curly + 1;
    var scan = curly + 1;

    while (scan < stop) : (scan += 1) {
        const kind = emitter.tokens[scan].kind;
        const opens = walk.is_open(kind) or kind == .block_start;
        const closes = walk.is_close(kind) or kind == .block_end;
        const separated = depth == 0 and kind.eql(.{ .punctuation = .comma });

        if (opens) depth += 1;
        if (closes) depth -|= 1;
        if (!separated) continue;

        if (variant_read(emitter, start, scan)) |wide| {
            parted = parted or wide;
            lined = lined or !wide;
        }

        start = scan + 1;
    }

    if (variant_read(emitter, start, end)) |wide| {
        parted = parted or wide;
        lined = lined or !wide;
    }

    return lined and parted;
}

fn variant_read(emitter: *const Emitter, from: u32, to: u32) ?bool {
    assert(from <= to + 1);
    assert(to < emitter.count);

    const held = variant_skipped(emitter, from, to);
    if (held >= to) return null;

    const token = emitter.tokens[held];
    const bytes = token.text(emitter.source);
    const documented = std.mem.startsWith(u8, bytes, "///") or std.mem.startsWith(u8, bytes, "//!");
    const marked = walk.text_is(bytes, "#") or (token.kind == .comment and documented);
    if (marked) return true;
    return variant_wide(emitter, held, to);
}

fn variant_skipped(emitter: *const Emitter, from: u32, to: u32) u32 {
    assert(to < emitter.count);
    assert(from <= to + 1);

    var held = from;

    while (held < to) : (held += 1) {
        const token = emitter.tokens[held];
        if (token.length == 0) continue;
        if (token.kind != .comment) break;

        const bytes = token.text(emitter.source);
        if (std.mem.startsWith(u8, bytes, "///")) break;
        if (std.mem.startsWith(u8, bytes, "//!")) break;
    }

    return held;
}

fn variant_wide(emitter: *const Emitter, held: u32, to: u32) bool {
    assert(held < to);
    assert(to < emitter.count);

    const open = emit.ahead_of(emitter, held) orelse return false;
    if (open >= to) return false;

    const kind = emitter.tokens[open].kind;
    const braced = kind == .block_start;

    if (!braced) {
        if (!kind.eql(.{ .punctuation = .paren_open })) return false;
    }

    const close = join.closing_of(emitter, open) orelse return false;
    if (close >= to) return false;
    if (variant_marked(emitter, open, close)) return true;

    const lead = emit.ahead_of(emitter, open) orelse return false;
    const tail = emit.back_of(emitter, close) orelse return false;
    if (lead > tail) return false;

    const bound = if (braced) emitter.policy.variant_width else emitter.policy.call_width;
    return flat_columns(emitter, lead, tail + 1) > bound;
}

fn variant_marked(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    const braced = emitter.tokens[open].kind == .block_start;
    var depth: u32 = 0;
    var scan = open + 1;

    while (scan < close) : (scan += 1) {
        const token = emitter.tokens[scan];
        const bytes = token.text(emitter.source);

        if (token.kind == .comment) {
            if (std.mem.startsWith(u8, bytes, "//")) return true;
        }

        if (braced) {
            if (depth == 0) {
                if (walk.text_is(bytes, "#")) return true;
            }
        }

        if (walk.is_open(token.kind)) depth += 1;
        if (walk.is_close(token.kind)) depth -|= 1;
    }

    return false;
}

fn varied_brace(emitter: *const Emitter, open: u32) ?u32 {
    assert(open < emitter.count);

    if (emitter.policy.variant_width == 0) return null;

    var depth: u32 = 0;
    var scan = open;

    for (0..variant_scan_max) |_| {
        var held = emit.back_of(emitter, scan) orelse return null;
        const kind = emitter.tokens[held].kind;
        const closes = walk.is_close(kind) or kind == .block_end;
        const opens = walk.is_open(kind) or kind == .block_start;

        assert(held < scan);

        if (closes) {
            if (depth == 0) {
                held = emitter.brackets.open_of(held) orelse return null;
            } else {
                depth += 1;
            }
        } else if (opens) {
            if (depth > 0) {
                depth -= 1;
            } else {
                if (kind != .block_start) return null;
                if (line.head_word(emitter, held, enum_words) == null) return null;
                return held;
            }
        } else {}

        scan = held;
    }

    return null;
}

fn braced_line(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    return probed(emitter, probe_of(.braced_line, position, 0));
}

fn braced_head(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);

    if (core.memo_found(emitter, .braced_head, position, 0)) |answer| {
        return if (answer == core.memo_none) null else answer;
    }

    const held = braced_head_scanned(emitter, position);

    core.memo_store(emitter, .braced_head, position, 0, held orelse core.memo_none);

    return held;
}

fn braced_head_scanned(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);

    var depth: u32 = 0;
    var scan = position;

    for (0..core.type_scan_max) |_| {
        const held = emit.back_of(emitter, scan) orelse return null;
        const from = emitter.tokens[held].end();
        const to = emitter.tokens[scan].offset;

        assert(held < scan);

        if (body.parted_by(emitter, from, to) > 0) return null;

        const kind = emitter.tokens[held].kind;
        const closes = walk.is_close(kind) or kind == .block_end;
        const opens = walk.is_open(kind) or kind == .block_start;
        const headed = kind == .block_start and depth == 0;
        if (headed) return held;

        if (closes) {
            depth += 1;
        } else if (opens) {
            if (depth > 0) depth -= 1;
        } else {}

        scan = held;
    }

    return null;
}

fn branch_head(emitter: *const Emitter, open: u32) ?u32 {
    assert(open < emitter.count);

    var assigned = false;
    var depth: u32 = 0;
    var scan = open;

    for (0..core.type_scan_max) |_| {
        scan = emit.back_of(emitter, scan) orelse return null;

        const token = emitter.tokens[scan];

        if (token.kind == .block_end) {
            scan = emit.opened(emitter, scan) orelse return null;

            continue;
        }

        if (walk.is_close(token.kind)) {
            depth += 1;

            continue;
        }

        const opens = walk.is_open(token.kind) or token.kind == .block_start;

        if (opens) {
            if (depth == 0) return null;

            depth -= 1;

            continue;
        }

        assert(depth <= core.type_scan_max);

        if (depth > 0) continue;
        if (line.word_is(emitter, scan, emitter.policy.branch_words)) return scan;

        const separated = token.is_punctuation(.comma) or token.is_punctuation(.semicolon);
        if (separated) return null;
        if (text_is(emitter, scan, "=>")) return null;

        if (text_is(emitter, scan, "=")) assigned = true;

        if (!assigned) {
            if (text_is(emitter, scan, "let")) return null;
        }
    }

    return null;
}

pub fn branched(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    return probed(emitter, probe_of(.branched, open, 0));
}

fn branched_over(emitter: *const Emitter, head: u32) bool {
    assert(head < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const end = branch_end(emitter, head) orelse return false;
    const from = emitter.tokens[head].offset;
    const to = emitter.tokens[end].end();

    assert(end > head);

    if (body.parted_by(emitter, from, to) > 0) return false;
    return walk.columns(emitter.source, from, to) > emitter.policy.branch_width;
}

fn branch_end(emitter: *const Emitter, head: u32) ?u32 {
    assert(head < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var scan = head;

    for (0..core.type_scan_max) |_| {
        const open = branch_brace(emitter, scan) orelse return null;
        const close = emit.closing(emitter, open) orelse return null;
        const ahead = emit.ahead_of(emitter, close) orelse return close;

        assert(open > scan);

        if (!text_is(emitter, ahead, "else")) return close;

        scan = ahead;
    }

    return null;
}

fn branch_brace(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var scan = position;

    for (0..core.type_scan_max) |_| {
        const held = bracket_after(emitter, scan) orelse return null;
        const back = emit.back_of(emitter, held);
        const opened = if (back) |found| line.word_is(emitter, found, branch_openers) else false;

        assert(held > scan);

        if (!opened) return held;

        scan = emit.closing(emitter, held) orelse return null;
    }

    return null;
}

fn bracket_after(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var depth: u32 = 0;
    var scan = position;

    for (0..core.type_scan_max) |_| {
        const held = emit.ahead_of(emitter, scan) orelse return null;
        const kind = emitter.tokens[held].kind;
        const opens = walk.is_open(kind) or kind == .block_start;
        const closes = walk.is_close(kind) or kind == .block_end;

        assert(held > scan);

        if (depth == 0) {
            if (kind == .block_start) return held;
        }

        if (opens) {
            depth += 1;
        } else if (closes) {
            if (depth == 0) return null;

            depth -= 1;
        } else {}

        scan = held;
    }

    return null;
}

fn branched_line(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    if (emitter.policy.branch_width == 0) return false;
    if (!emitter.policy.block_chains) return false;

    const head = emit.ahead_of(emitter, open) orelse return false;
    if (head >= close) return false;
    if (!line.word_is(emitter, head, emitter.policy.branch_words)) return false;
    return branched_over(emitter, head);
}

fn commented_value(emitter: *const Emitter, value: u32) bool {
    assert(value < emitter.count);

    var commented = false;
    var scan = value;

    for (0..core.type_scan_max) |_| {
        const held = emit.back_of(emitter, scan) orelse return false;
        const token = emitter.tokens[held];
        const kind = token.kind;
        const stopped = line.word_is(emitter, held, comment_stops);
        const bracketed = walk.is_open(kind) or walk.is_close(kind);
        const blocked = kind == .block_end or kind == .block_start;
        const separated = token.is_punctuation(.comma) or token.is_punctuation(.semicolon);
        const bounded = bracketed or blocked or separated;

        assert(held < scan);

        if (kind == .comment) {
            commented = true;
        } else if (stopped) {
            return commented;
        } else if (bounded) {
            return false;
        } else {}

        scan = held;
    }

    return false;
}

pub fn listed(emitter: *const Emitter, open: u32) ?u32 {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (core.lined_found(emitter, open)) |answer| {
        return if (answer == core.memo_none) null else answer;
    }

    const point = join.point_of(join.evaluated(emitter, listing_frame(emitter, open)));

    core.lined_store(emitter, open, point orelse core.memo_none);

    return point;
}

pub fn listing_frame(emitter: *const Emitter, open: u32) join.Frame {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    return .{ .listing = .{
        .close = open,
        .open = open,
        .shut = open,
        .target = open,
        .defined = false,
        .phase = .start,
    } };
}

pub fn listing_step(emitter: *const Emitter, listing: *Listing, answer: ?bool) join.Step {
    assert(listing.open < emitter.count);
    assert(listing.target < emitter.count);
    if (answer == null) assert(listing.phase != .braced);

    const braced = answer orelse return listing_start(emitter, listing);

    if (listing.phase == .hugged) {
        const target = listing.target;
        const tail_hugged = !braced and hugged_tail(emitter, target);
        if (tail_hugged) return listing_found(emitter, listing, target);
        return listing_found(emitter, listing, listed_measured(emitter, target, listing.shut));
    }

    assert(listing.phase == .braced);

    return listing_braced(emitter, listing, braced);
}

fn listing_start(emitter: *const Emitter, listing: *Listing) join.Step {
    assert(listing.phase != .braced);
    assert(listing.phase != .hugged);

    if (listing.phase == .start) {
        const open = listing.open;
        const close = join.closing_of(emitter, open) orelse return .{ .found = null };

        assert(open < close);

        if (!listed_admitted(emitter, open, close)) return .{ .found = null };

        listing.close = close;
        listing.shut = close;
        listing.defined = defined(emitter, open);

        if (listing.defined) {
            const target, const shut = returned_target(emitter, close) orelse
                return listing_found(emitter, listing, null);

            listing.target = target;
            listing.shut = shut;
        }
    }

    listing.phase = .braced;

    return .{ .call = .{ .probe = probe_of(.braced_line, listing.target, 0) } };
}

fn listing_braced(emitter: *const Emitter, listing: *Listing, braced: bool) join.Step {
    assert(listing.phase == .braced);
    assert(listing.target < listing.shut);

    const target = listing.target;
    const shut = listing.shut;

    if (braced) return listing_found(emitter, listing, null);
    if (commented_value(emitter, target)) return listing_found(emitter, listing, null);
    if (tupled_sole(emitter, target, shut)) return listing_found(emitter, listing, null);
    if (returned_over(emitter, target, shut)) return listing_found(emitter, listing, target);
    if (branched_last(emitter, target, shut)) return listing_found(emitter, listing, target);
    if (listed_lined(emitter, target, shut)) return listing_found(emitter, listing, target);
    if (strung_wide(emitter, target, shut)) return listing_found(emitter, listing, target);
    if (strung_hugged(emitter, target, shut)) return listing_found(emitter, listing, null);

    if (hugged_admitted(emitter, target)) {
        listing.phase = .hugged;

        return .{ .call = .{ .probe = probe_of(.braced_line, target, 0) } };
    }

    return listing_found(emitter, listing, listed_measured(emitter, target, shut));
}

fn listing_found(emitter: *const Emitter, listing: *const Listing, opened: ?u32) join.Step {
    assert(listing.open < listing.close);
    assert(listing.close < emitter.count);
    if (opened) |held| assert(held < emitter.count);

    if (!listing.defined) return .{ .found = opened };
    if (opened != null) return .{ .found = listing.open };
    if (defined_wide(emitter, listing.open, listing.close)) return .{ .found = listing.open };
    return .{ .found = null };
}

fn listed_admitted(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < emitter.count);
    assert(close < emitter.count);

    if (core.memo_found(emitter, .listed_admitted, open, close)) |answer| return answer == 1;

    const held = listed_admitted_scanned(emitter, open, close);

    core.memo_store(emitter, .listed_admitted, open, close, @intFromBool(held));

    return held;
}

fn listed_admitted_scanned(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    if (sole.listed(emitter, close)) return true;
    return macroed(emitter, open, close);
}

pub fn returned_parted(emitter: *const Emitter, close: u32) bool {
    assert(close < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const open, const shut = returned_target(emitter, close) orelse return false;

    const root: join.Frame = .{ .listing = .{
        .close = shut,
        .open = open,
        .shut = shut,
        .target = open,
        .defined = false,
        .phase = .open,
    } };

    return join.point_of(join.evaluated(emitter, root)) != null;
}

fn returned_target(emitter: *const Emitter, close: u32) ?struct { u32, u32 } {
    assert(close < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const arrow = emit.ahead_of(emitter, close) orelse return null;
    if (!text_is(emitter, arrow, "->")) return null;

    const open = emit.ahead_of(emitter, arrow) orelse return null;
    if (!walk.is_open(emitter.tokens[open].kind)) return null;

    const shut = join.closing_of(emitter, open) orelse return null;

    assert(open < shut);

    if (!listed_admitted(emitter, open, shut)) return null;

    assert(!defined(emitter, open));

    return .{ open, shut };
}

fn listed_measured(emitter: *const Emitter, open: u32, close: u32) ?u32 {
    assert(open < close);
    assert(close < emitter.count);

    const held = sole_call(emitter, open);
    const stop = join.closing_of(emitter, held) orelse return null;
    const nests = emitter.policy.call_nests;
    const measured = if (nests) open else held;
    const ends = if (nests) close else stop;
    const from = emitter.tokens[measured].end();
    const to = emitter.tokens[ends].offset;

    if (chained_sole(emitter, open, close)) return listed_soled(emitter, open, close, held);

    const rooted_close = listed_rooted(emitter, close);
    const overflowed = emitter.policy.call_budgets and held != open and !rooted_close;
    const tailed = tailed_close(emitter, ends, measured);
    const mixed = held == open and comma_mixed(emitter, open, close);
    const deeper = overflowed and sole_deeper(emitter, held, close);
    const refused = held == open and hug_refused(emitter, open, close);
    const flattened = mixed or deeper or refused;

    const spelled = if (flattened)
        flat_columns(emitter, measured + 1, ends)
    else
        walk.columns(emitter.source, from, to) - indexed_gaps(emitter, measured, ends);

    const trimmed = tailed or (overflowed and tailed_comma(emitter, measured, ends));
    const width = spelled - @intFromBool(trimmed);

    if (mixed) {
        if (comma_commented(emitter, open, close)) return held;
    }

    if (!flattened) {
        if (body.parted_by(emitter, from, to) > 0) return null;
    }

    if (linked_wide(emitter, open, close)) return held;

    const extent: Listed = .{
        .close = close,
        .held = held,
        .open = open,
        .overflowed = overflowed,
        .rooted = rooted_close,
        .stop = stop,
    };

    return listed_over(emitter, &extent, width);
}

fn hug_refused(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    if (!emitter.policy.call_budgets) return false;

    const last = hug_last(emitter, open, close) orelse return false;
    const tail = emit.back_of(emitter, close) orelse return false;
    const kind = emitter.tokens[tail].kind;

    if (tail < last) return false;

    if (!walk.is_close(kind)) {
        if (kind != .block_end) return false;
    }

    const opener = emitter.brackets.open_of(tail) orelse return false;
    if (opener < last) return false;

    const head = emitter.tokens[open].end();
    const inside = emitter.tokens[opener].end();
    const after = emitter.tokens[tail].end();

    if (body.parted_by(emitter, head, inside) > 0) return false;
    if (body.parted_by(emitter, after, emitter.tokens[close].offset) > 0) return false;
    if (body.parted_by(emitter, inside, emitter.tokens[tail].offset) == 0) return false;

    const inner = emit.back_of(emitter, tail) orelse return false;
    if (!body.parts_at(emitter, inner, tail)) return false;
    return !hug_overflows(emitter, last, opener);
}

pub fn sole_horizontal(emitter: *const Emitter, close: u32) bool {
    assert(close < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.call_budgets) return false;
    if (!emitter.tokens[close].is_punctuation(.paren_close)) return false;

    const open = emitter.brackets.open_of(close) orelse return false;
    const callee = emit.back_of(emitter, open) orelse return false;
    if (emitter.tokens[callee].kind != .identifier) return false;
    if (!sole_combined(emitter, callee)) return false;
    if (hug_last(emitter, open, close) != null) return false;

    const lead = emit.ahead_of(emitter, open) orelse return false;
    const tail = emit.back_of(emitter, close) orelse return false;
    if (lead > tail) return false;
    if (emitter.tokens[tail].is_punctuation(.comma)) return false;

    if (body.parted_by(emitter, emitter.tokens[lead].offset, emitter.tokens[tail].end()) > 0) {
        return false;
    }

    return flat_columns(emitter, lead, close) <= emitter.policy.call_width;
}

fn sole_combined(emitter: *const Emitter, callee: u32) bool {
    assert(callee < emitter.count);
    assert(emitter.tokens[callee].kind == .identifier);

    const length = emitter.tokens[callee].length;
    const indent = emitter.options.indent_width;
    const before = emit.back_of(emitter, callee) orelse return length < indent;
    if (emit.is_dot(emitter, before)) return length + 1 < indent;
    if (text_is(emitter, before, "::")) return false;
    return length < indent;
}

fn hug_last(emitter: *const Emitter, open: u32, close: u32) ?u32 {
    assert(open < close);
    assert(close < emitter.count);

    const angles = emitter.brackets.angles_at(open);
    var barred = false;
    var depth: u32 = 0;
    var last: ?u32 = null;
    var prior: ?u32 = null;
    var scan = emit.ahead_of(emitter, open) orelse return null;

    for (0..core.type_scan_max) |_| {
        if (scan >= close) return last;

        const kind = emitter.tokens[scan].kind;
        const opens = walk.is_open(kind) or kind == .block_start;
        const closes = walk.is_close(kind) or kind == .block_end;
        const barring = depth == 0 and text_is(emitter, scan, "|");
        const separates = depth == 0 and !barred and kind.eql(.{ .punctuation = .comma });
        const toggles = barring and (barred or operand_opens(emitter, prior));
        const item_separator = separates and emitter.brackets.angles_at(scan) == angles;

        if (opens) {
            depth += 1;
        } else if (closes) {
            depth -|= 1;
        } else {
            if (toggles) barred = !barred;

            if (item_separator) {
                const next = emit.ahead_of(emitter, scan) orelse return null;

                if (next < close) last = next;
            }
        }

        prior = scan;
        scan = emit.ahead_of(emitter, scan) orelse return null;
    }

    return null;
}

fn hug_overflows(emitter: *const Emitter, last: u32, opener: u32) bool {
    assert(last <= opener);
    assert(opener < emitter.count);

    var scan = last;

    for (0..core.type_scan_max) |_| {
        if (scan >= opener) break;
        if (!line.word_is(emitter, scan, hug_prefixes)) break;

        scan = emit.ahead_of(emitter, scan) orelse return false;
    }

    if (text_is(emitter, scan, "|")) return true;
    if (text_is(emitter, scan, "||")) return true;
    if (emitter.tokens[opener].kind != .block_start) return false;

    for (0..core.type_scan_max) |_| {
        if (scan >= opener) return scan == opener;
        if (!line.word_is(emitter, scan, hug_heads)) return false;

        scan = emit.ahead_of(emitter, scan) orelse return false;
    }

    return false;
}

fn indexed_gaps(emitter: *const Emitter, open: u32, close: u32) u32 {
    assert(open < close);
    assert(close < emitter.count);

    var gaps: u32 = 0;
    var scan = open + 1;

    while (scan < close) : (scan += 1) {
        const token = emitter.tokens[scan];
        if (token.kind != .number) continue;
        if (!split.number_indexed(emitter, scan)) continue;

        const next = emit.ahead_of(emitter, scan) orelse continue;
        if (next >= close) continue;
        if (!emit.is_dot(emitter, next)) continue;

        gaps += @intFromBool(token.end() < emitter.tokens[next].offset);
    }

    return gaps;
}

fn listed_soled(emitter: *const Emitter, open: u32, close: u32, held: u32) ?u32 {
    assert(open < close);
    assert(held >= open);

    if (chained_soled(emitter, open)) {
        if (chained_lined(emitter, open, close)) return held;
        return null;
    }

    const stop = join.closing_of(emitter, held) orelse return null;
    const nests = emitter.policy.call_nests;
    const measured = if (nests) open else held;
    const ends = if (nests) close else stop;
    const point = chained_point(emitter, open, close, ends);
    if (flat_columns(emitter, measured + 1, point) > emitter.policy.call_width) return held;
    return null;
}

fn sole_deeper(emitter: *const Emitter, held: u32, close: u32) bool {
    assert(held < close);
    assert(close < emitter.count);

    const from = emitter.tokens[held].end();
    const to = emitter.tokens[close].offset;
    const breaks = body.parted_by(emitter, from, to);
    if (breaks == 0) return false;

    var inner = held;

    for (0..brace.nest_depth_max) |_| {
        inner = sole_inner(emitter, inner) orelse return false;

        const lead = emit.ahead_of(emitter, inner) orelse return false;
        const shut = join.closing_of(emitter, inner) orelse return false;
        const tail = emit.back_of(emitter, shut) orelse return false;
        const head_end = emitter.tokens[inner].end();
        const tail_end = emitter.tokens[tail].end();
        const head_breaks = body.parted_by(emitter, head_end, emitter.tokens[lead].offset);
        const tail_breaks = body.parted_by(emitter, tail_end, emitter.tokens[shut].offset);
        const edges = head_breaks + tail_breaks;
        if (edges > 0) return edges == breaks;
    }

    return false;
}

fn tailed_comma(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    var scan = emit.back_of(emitter, close);

    for (0..brace.nest_depth_max) |_| {
        const held = scan orelse return false;
        if (held <= open) return false;

        const kind = emitter.tokens[held].kind;
        const closes = walk.is_close(kind) or kind == .block_end;
        if (!closes) return kind.eql(.{ .punctuation = .comma });

        scan = emit.back_of(emitter, held);
    }

    return false;
}

fn listed_rooted(emitter: *const Emitter, close: u32) bool {
    assert(close < emitter.count);

    const ahead = emit.ahead_of(emitter, close) orelse return false;

    assert(ahead > close);

    return dotted(emitter, ahead);
}

fn listed_over(emitter: *const Emitter, extent: *const Listed, width: u32) ?u32 {
    assert(extent.open < extent.close);
    assert(extent.stop < emitter.count);

    const bound = bound_patterned(emitter, extent.open) and
        bound_fits(emitter, extent.open, extent.close);

    const patterned = bound or arm_patterned(emitter, extent.close);
    const budget = if (patterned) emitter.options.line_width else emitter.policy.call_width;

    if (width <= budget) {
        if (!listed_broken(emitter, extent.open, extent.close)) return null;
    }

    if (lambda_soled(emitter, extent.open, extent.close)) return null;
    if (lambda_hung_list(emitter, extent.held) != null) return null;
    if (extent.overflowed) return extent.held;
    if (elemental_list(emitter, extent.held, extent.stop)) return extent.held;

    if (emitter.policy.hug_lambdas) {
        if (join.lambdas_in(emitter, extent.open, extent.close) > 1) return extent.held;
    }

    if (lambda_listed(emitter, extent.open, extent.close)) return extent.held;
    if (lambda_headed(emitter, extent.open, extent.close)) return extent.held;
    if (chained_sole(emitter, extent.open, extent.close)) return extent.held;
    if (stringed_wide(emitter, extent.open, extent.close, extent.rooted)) return extent.held;
    return null;
}

pub fn defined(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    if (core.memo_found(emitter, .defined, open, 0)) |answer| return answer == 1;

    const held = defined_scanned(emitter, open);

    core.memo_store(emitter, .defined, open, 0, @intFromBool(held));

    return held;
}

fn defined_scanned(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    const held = emit.back_of(emitter, open);
    const arrowed = if (held) |found| text_is(emitter, found, "->") else false;
    const returned = arrowed or return_nested(emitter, open);
    if (returned) return false;
    return line.worded_head(emitter, open, emitter.policy.define_words);
}

fn return_nested(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    var scan = open;

    for (0..core.type_scan_max) |_| {
        const held = emit.back_of(emitter, scan) orelse return false;
        const kind = emitter.tokens[held].kind;

        assert(held < scan);

        if (text_is(emitter, held, "->")) return scan != open;

        if (walk.is_close(kind)) {
            scan = emitter.brackets.open_of(held) orelse return false;

            continue;
        }

        const typed = kind == .identifier or line.word_is(emitter, held, nested_types);
        if (!typed) return false;

        scan = held;
    }

    return false;
}

fn tupled_sole(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < emitter.count);
    assert(close < emitter.count);

    if (core.memo_found(emitter, .tupled_sole, open, close)) |answer| return answer == 1;

    const held = tupled_sole_scanned(emitter, open, close);

    core.memo_store(emitter, .tupled_sole, open, close, @intFromBool(held));

    return held;
}

fn tupled_sole_scanned(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    if (listed_count(emitter, open, close) != 1) return false;
    return tupled_define(emitter, open);
}

fn tupled_define(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (!emitter.tokens[open].is_punctuation(.paren_open)) return false;

    const held = emit.back_of(emitter, open) orelse return false;
    if (emitter.tokens[held].kind != .identifier) return false;
    if (line.worded_head(emitter, open, tuple_words)) return true;

    var level = emitter.depth;

    while (level > 0) {
        level -= 1;

        const frame = emitter.nest[level];

        if (frame.kind == .block_start) {
            if (frame.open >= open) return false;
            return line.worded_head(emitter, frame.open, tuple_words);
        }
    }

    return false;
}

fn listed_count(emitter: *const Emitter, open: u32, close: u32) u32 {
    assert(open < emitter.count);
    assert(close < emitter.count);

    if (core.memo_found(emitter, .listed_count, open, close)) |answer| return answer;

    const held = listed_count_scanned(emitter, open, close);

    core.memo_store(emitter, .listed_count, open, close, held);

    return held;
}

fn listed_count_scanned(emitter: *const Emitter, open: u32, close: u32) u32 {
    assert(open < close);
    assert(close < emitter.count);

    var depth: u32 = 0;
    var held: u32 = 1;
    var lambda = false;
    var prior: ?u32 = null;
    var scan = open + 1;

    while (scan < close) : (scan += 1) {
        const token = emitter.tokens[scan];
        const kind = token.kind;
        const opens = operand_opens(emitter, prior);
        const barring = depth == 0 and text_is(emitter, scan, "|");
        const toggles = barring and (lambda or opens);
        const separates = depth == 0 and !lambda and token.is_punctuation(.comma);

        if (toggles) {
            lambda = !lambda;
        } else if (walk.is_open(kind)) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            depth -|= 1;
        } else {}

        if (separates) {
            if (listed_count_counts(emitter, scan, close)) held += 1;
        }

        if (token.length > 0) prior = scan;
    }

    assert(held <= close - open);

    return held;
}

fn listed_count_counts(emitter: *const Emitter, comma: u32, close: u32) bool {
    assert(comma < close);
    assert(commas(emitter, comma));

    if (emit.ahead_of(emitter, comma) == close) return false;
    return join.angle_head(emitter, comma) == null;
}

fn statement_word(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);

    if (core.memo_found(emitter, .statement_word, position, 0)) |answer| {
        return if (answer == core.memo_none) null else answer;
    }

    const held = statement_word_scanned(emitter, position);

    core.memo_store(emitter, .statement_word, position, 0, held orelse core.memo_none);

    return held;
}

fn statement_word_scanned(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);

    var head = edge.statement_head(emitter, position) orelse return null;

    for (0..core.type_scan_max) |_| {
        assert(head < emitter.count);

        const commented = emitter.tokens[head].kind == .comment;
        const skipped = if (commented) head else attribute_closed(emitter, head) orelse return head;

        head = emit.ahead_of(emitter, skipped) orelse return null;
    }

    return null;
}

fn attribute_closed(emitter: *const Emitter, head: u32) ?u32 {
    assert(head < emitter.count);

    if (!text_is(emitter, head, "#")) return null;

    var open = emit.ahead_of(emitter, head) orelse return null;

    if (emitter.tokens[open].is_punctuation(.bang)) {
        open = emit.ahead_of(emitter, open) orelse return null;
    }

    if (!emitter.tokens[open].is_punctuation(.bracket_open)) return null;
    return join.closing_of(emitter, open);
}

pub fn returned_over(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    const head = statement_word(emitter, open) orelse return false;
    if (head >= open) return false;
    if (!line.word_is(emitter, head, return_words)) return false;
    if (element_count(emitter, open, close) != 1) return false;
    if (sole_called(emitter, open)) return false;

    if (operand_of(emitter, open)) |lead| {
        if (line.word_is(emitter, lead, lambda_leads)) return false;
    }

    const end = statement_close(emitter, close);
    const flat = indent_of(emitter, head) + flat_columns(emitter, head, end + 1);

    assert(end >= close);

    if (flat > emitter.options.line_width) return false;
    return flat + return_room > emitter.options.line_width;
}

pub fn returned_room(emitter: *const Emitter, lead: u32) u32 {
    assert(lead < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!line.word_is(emitter, lead, return_words)) return 0;
    return return_room;
}

fn sole_called(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    var scan = operand_of(emitter, open) orelse return false;

    for (0..core.type_scan_max) |_| {
        const token = emitter.tokens[scan];

        assert(scan > open);

        if (token.is_punctuation(.paren_open)) return true;

        const worded = token.kind == .identifier or token.kind == .keyword;
        const glued = text_is(emitter, scan, "::") or text_is(emitter, scan, "!");

        if (!worded) {
            if (!glued) return false;
        }

        scan = emit.ahead_of(emitter, scan) orelse return false;
    }

    return false;
}

fn statement_close(emitter: *const Emitter, close: u32) u32 {
    assert(close < emitter.count);

    const ahead = emit.ahead_of(emitter, close) orelse return close;

    assert(ahead > close);

    if (emitter.tokens[ahead].is_punctuation(.semicolon)) return ahead;

    var scan = ahead;

    for (0..import_tail_max) |_| {
        const token = emitter.tokens[scan];
        if (token.is_punctuation(.semicolon)) return scan;

        const worded = token.kind == .identifier or token.kind == .keyword;
        const named_tail = worded or token.kind == .string;
        if (!named_tail) return close;

        scan = emit.ahead_of(emitter, scan) orelse return close;
    }

    return close;
}

fn branched_last(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < emitter.count);
    assert(close < emitter.count);

    if (core.memo_found(emitter, .branched_last, open, close)) |answer| return answer == 1;

    const held = branched_last_scanned(emitter, open, close);

    core.memo_store(emitter, .branched_last, open, close, @intFromBool(held));

    return held;
}

fn branched_last_scanned(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    if (element_count(emitter, open, close) < 2) return false;
    if (macroed(emitter, open, close)) return false;

    const tail = listed_last(emitter, open, close) orelse return false;
    if (!line.word_is(emitter, tail, branch_last_words)) return false;

    const stop = emit.back_of(emitter, close) orelse return false;
    if (stop <= tail) return false;
    if (!text_is(emitter, tail, "if")) return true;
    if (!elsed(emitter, tail, stop)) return true;
    return flat_columns(emitter, tail, stop + 1) > emitter.policy.else_width;
}

fn elsed(emitter: *const Emitter, from: u32, stop: u32) bool {
    assert(from <= stop);
    assert(stop < emitter.count);

    var depth: u32 = 0;
    var scan = from;

    while (scan <= stop) : (scan += 1) {
        const kind = emitter.tokens[scan].kind;
        const opens = walk.is_open(kind) or kind == .block_start;
        const closes = walk.is_close(kind) or kind == .block_end;

        if (opens) {
            depth += 1;
        } else if (closes) {
            depth -|= 1;
        } else if (depth == 0) {
            if (text_is(emitter, scan, "else")) return true;
        } else {}
    }

    return false;
}

fn listed_lined(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    const tail = listed_last(emitter, open, close) orelse return false;
    var scan = open + 1;

    assert(tail < close);

    while (scan < tail) : (scan += 1) {
        const bytes = emitter.tokens[scan].text(emitter.source);
        if (std.mem.findScalar(u8, bytes, '\n') != null) return true;
    }

    return false;
}

fn strung_wide(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    if (!emitter.policy.call_budgets) return false;

    const tail = strung_last(emitter, open, close) orelse return false;
    if (!strung_spans(emitter, tail, close)) return false;
    if (strung_lambda(emitter, tail)) return false;
    if (listed_count(emitter, open, close) > 1) return true;
    if (strung_callee(emitter, open) < emitter.options.indent_width) return false;
    return !strung_overflows(emitter, tail, close);
}

fn strung_hugged(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    if (!emitter.policy.call_budgets) return false;

    const tail = strung_last(emitter, open, close) orelse return false;

    if (listed_count(emitter, open, close) != 1) return false;
    if (strung_callee(emitter, open) >= emitter.options.indent_width) return false;

    for (tail..close) |index| {
        const token = emitter.tokens[index];
        if (token.kind != .string) continue;

        const broken = std.mem.findScalar(u8, token.text(emitter.source), '\n') orelse continue;
        const first = emitter.tokens[tail].offset;

        return walk.columns(emitter.source, first, token.offset + @as(u32, @intCast(broken))) <=
            emitter.policy.call_width;
    }

    return false;
}

fn strung_last(emitter: *const Emitter, open: u32, close: u32) ?u32 {
    assert(open < close);
    assert(close < emitter.count);

    var depth: u32 = 0;
    var lambda = false;
    var last: ?u32 = null;
    var fresh = true;
    var prior: ?u32 = null;
    var scan = open + 1;

    while (scan < close) : (scan += 1) {
        const token = emitter.tokens[scan];
        if (token.length == 0) continue;
        if (token.kind == .newline) continue;
        if (token.kind == .comment) continue;

        if (fresh) {
            last = scan;
            fresh = false;
        }

        const barring = depth == 0 and text_is(emitter, scan, "|");
        const toggles = barring and (lambda or operand_opens(emitter, prior));

        if (toggles) {
            lambda = !lambda;
        } else if (walk.is_open(token.kind)) {
            depth += 1;
        } else if (walk.is_close(token.kind)) {
            depth -|= 1;
        } else {
            const separates = depth == 0 and !lambda and token.is_punctuation(.comma);

            if (separates) fresh = true;
        }

        prior = scan;
    }

    return last;
}

pub fn strung_spans(emitter: *const Emitter, tail: u32, close: u32) bool {
    assert(tail < close);
    assert(close < emitter.count);

    for (emitter.tokens[tail..close]) |token| {
        if (token.kind != .string) continue;
        if (std.mem.findScalar(u8, token.text(emitter.source), '\n') != null) return true;
    }

    return false;
}

fn strung_lambda(emitter: *const Emitter, tail: u32) bool {
    assert(tail < emitter.count);

    if (emitter.tokens[tail].kind == .block_start) return true;
    if (line.word_is(emitter, tail, lambda_leads)) return true;
    if (!line.word_is(emitter, tail, &.{ "async", "const", "unsafe" })) return false;

    const next = emit.ahead_of(emitter, tail) orelse return false;
    if (emitter.tokens[next].kind == .block_start) return true;
    return line.word_is(emitter, next, lambda_leads);
}

fn strung_callee(emitter: *const Emitter, open: u32) u32 {
    assert(open < emitter.count);

    const head = callee_head(emitter, open);
    if (head == open) return 0;

    const from = emitter.tokens[head].offset;
    const columns = walk.columns(emitter.source, from, emitter.tokens[open].offset);
    const dot = emit.back_of(emitter, head) orelse return columns;
    const returned = columns + @intFromBool(text_is(emitter, dot, "."));

    assert(returned < std.math.maxInt(u32));

    return returned;
}

fn strung_overflows(emitter: *const Emitter, tail: u32, close: u32) bool {
    assert(tail < close);
    assert(close < emitter.count);

    if (line.word_is(emitter, tail, branch_last_words)) return true;
    if (text_is(emitter, tail, "unsafe")) return true;

    var last = emit.back_of(emitter, close) orelse return false;

    if (emitter.tokens[last].is_punctuation(.comma)) {
        last = emit.back_of(emitter, last) orelse return false;
    }

    if (last < tail) return false;
    if (text_is(emitter, last, "?")) last = emit.back_of(emitter, last) orelse return false;
    return walk.is_close(emitter.tokens[last].kind);
}

pub fn listed_last(emitter: *const Emitter, open: u32, close: u32) ?u32 {
    assert(open < close);
    assert(close < emitter.count);

    var barred = false;
    var depth: u32 = 0;
    var head = emit.ahead_of(emitter, open) orelse return null;
    if (head >= close) return null;

    var scan = head;

    for (0..core.type_scan_max) |_| {
        if (scan >= close) return head;

        const kind = emitter.tokens[scan].kind;
        const barring = depth == 0 and text_is(emitter, scan, "|");
        const separates = depth == 0 and !barred and kind.eql(.{ .punctuation = .comma });

        if (walk.is_open(kind)) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            depth -|= 1;
        } else if (barring) {
            barred = !barred;
        } else {}

        if (separates) {
            head = emit.ahead_of(emitter, scan) orelse return null;

            if (head >= close) return null;
        }

        scan = emit.ahead_of(emitter, scan) orelse return null;
    }

    return null;
}

fn hugged_call(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    const close = join.closing_of(emitter, open) orelse return false;
    const point = hugged_point(emitter, open, close) orelse return false;

    assert(point > open + 1);

    return flat_columns(emitter, open + 1, point) <= join.lambda_room(emitter, open, point - 1);
}

pub fn hugged(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    if (!hugged_admitted(emitter, open)) return false;
    if (braced_line(emitter, open)) return false;
    return hugged_tail(emitter, open);
}

fn hugged_admitted(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    if (core.memo_found(emitter, .hugged_admitted, open, 0)) |answer| return answer == 1;

    const held = hugged_admitted_scanned(emitter, open);

    core.memo_store(emitter, .hugged_admitted, open, 0, @intFromBool(held));

    return held;
}

fn hugged_admitted_scanned(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (emitter.policy.call_width == 0) return false;

    const close = join.closing_of(emitter, open) orelse return false;

    assert(open < close);

    if (!listed_admitted(emitter, open, close)) return false;
    return !defined(emitter, open);
}

fn hugged_tail(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (commented_value(emitter, open)) return false;

    const close = join.closing_of(emitter, open) orelse return false;
    const point = hugged_point(emitter, open, close) orelse return false;

    assert(point > open + 1);

    const flat = flat_columns(emitter, open + 1, point);
    if (flat <= join.lambda_room(emitter, open, point - 1)) return false;
    if (!hugged_sole(emitter, open, point - 1)) return true;
    return spread_of(emitter, open) + 1 + flat > emitter.options.line_width;
}

fn hugged_sole(emitter: *const Emitter, open: u32, curly: u32) bool {
    assert(open < curly);
    assert(curly < emitter.count);

    if (!emitter.policy.bar_aligns) return false;

    const head = hugged_head(emitter, curly, open) orelse return false;
    if (head == curly) return false;
    return emit.back_of(emitter, head) == open;
}

fn hugged_point(emitter: *const Emitter, open: u32, close: u32) ?u32 {
    assert(open < close);
    assert(close < emitter.count);

    const tail = emit.back_of(emitter, close) orelse return null;
    if (tail <= open) return null;

    const bracketed = emitter.policy.chain_simples and
        emitter.tokens[tail].is_punctuation(.bracket_close);

    const hugging = emitter.tokens[tail].kind == .block_end or bracketed;
    if (!hugging) return null;

    const curly = emitter.brackets.open_of(tail) orelse return null;
    if (curly <= open) return null;

    const head = hugged_head(emitter, curly, open) orelse return null;
    const behind = emit.back_of(emitter, head) orelse return null;
    const separated = behind == open or emitter.tokens[behind].is_punctuation(.comma);
    if (!separated) return null;
    assert(curly + 1 < std.math.maxInt(u32));

    return curly + 1;
}

fn hugged_head(emitter: *const Emitter, curly: u32, open: u32) ?u32 {
    assert(open < curly);
    assert(curly < emitter.count);

    var head = curly;
    const before = emit.back_of(emitter, curly) orelse return curly;
    if (before <= open) return curly;
    if (line.word_is(emitter, before, hug_heads)) return before;

    if (text_is(emitter, before, "||")) {
        head = before;
    } else if (text_is(emitter, before, "|")) {
        head = hugged_head_bar(emitter, before, open) orelse return null;
    } else {
        return curly;
    }

    assert(head < curly);

    const found = emit.back_of(emitter, head) orelse return head;
    if (found <= open) return head;
    if (text_is(emitter, found, "move")) return found;
    return head;
}

fn hugged_head_bar(emitter: *const Emitter, bar: u32, open: u32) ?u32 {
    assert(open < bar);
    assert(bar < emitter.count);

    var scan = emit.back_of(emitter, bar) orelse return null;

    for (0..core.type_scan_max) |_| {
        if (scan <= open) return null;
        if (text_is(emitter, scan, "|")) return scan;

        scan = emit.back_of(emitter, scan) orelse return null;
    }

    return null;
}

fn lambda_listed(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    if (emitter.tokens[open].kind == .block_start) return false;
    if (element_count(emitter, open, close) < 2) return false;
    if (hugged_call(emitter, open)) return false;

    const head = listed_last(emitter, open, close) orelse return false;
    if (!line.word_is(emitter, head, lambda_heads)) return false;

    var scan = head;

    while (scan < close) : (scan += 1) {
        if (spans_wide(emitter, scan)) return false;
        if (dotted(emitter, scan)) return false;
    }

    return true;
}

fn lambda_headed(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    if (emitter.tokens[open].kind == .block_start) return false;

    const lead = emit.ahead_of(emitter, open) orelse return false;
    if (lead >= close) return false;
    return line.word_is(emitter, lead, lambda_heads);
}

fn lambda_soled(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    if (listed_count(emitter, open, close) > 1) return false;
    if (!lambda_headed(emitter, open, close)) return false;
    return !elemental_list(emitter, open, close);
}

pub fn element_owed(emitter: *const Emitter, first: u32, head: u32, last: u32) bool {
    assert(head <= last);
    assert(last < emitter.count);

    if (first != head) return false;
    if (emitter.depth == 0) return false;

    const frame = emitter.nest[emitter.depth - 1];
    const parenthesized = frame.kind.eql(.{ .punctuation = .paren_open });
    const delimited = parenthesized or frame.kind.eql(.{ .punctuation = .bracket_open });
    if (!delimited) return false;
    if (frame.open >= head) return false;

    const close = join.closing_of(emitter, frame.open) orelse return false;
    return emit.ahead_of(emitter, last) == close;
}

pub fn kept_commas(emitter: *const Emitter, first: u32, last: u32) u32 {
    assert(first <= last);
    assert(last < emitter.count);

    if (!emitter.policy.macro_spans) return 0;

    var kept: u32 = 0;
    var scan = first;

    while (scan < last) : (scan += 1) {
        if (!emitter.tokens[scan].is_punctuation(.comma)) continue;

        const close = emit.ahead_of(emitter, scan) orelse continue;
        if (close > last) continue;
        if (!walk.is_close(emitter.tokens[close].kind)) continue;

        const open = emitter.brackets.open_of(close) orelse continue;
        if (open < first) continue;

        const before = emit.back_of(emitter, open) orelse continue;

        kept += @intFromBool(emitter.tokens[before].is_punctuation(.bang));
    }

    assert(kept <= last - first);

    return kept;
}

pub fn lambda_hung(emitter: *const Emitter, head: u32) bool {
    assert(head < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.call_budgets) return false;

    const start = lambda_start(emitter, head) orelse return false;
    const open = bind.enclosing_open(emitter, start) orelse return false;
    if (!emitter.tokens[open].is_punctuation(.paren_open)) return false;
    if (!lambda_macroed(emitter, open)) return false;

    const close = join.closing_of(emitter, open) orelse return false;
    const end, const links, _ = chain_end(emitter, head);

    if (links == 1) return false;

    if (links == 0) {
        if (lambda_called(emitter, head, end) == null) return false;
    }

    if (!lambda_closes(emitter, end, close)) return false;

    const budget = lambda_budget(emitter, open, start) orelse return false;
    return flat_columns(emitter, start, end + 1) > budget;
}

pub fn lambda_hung_parted(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(previous < position);
    assert(position < emitter.count);

    if (!emitter.policy.call_budgets) return false;

    if (emitter.tokens[previous].is_punctuation(.paren_open)) {
        return lambda_hung_call(emitter, previous);
    }

    if (emitter.tokens[previous].is_punctuation(.comma)) {
        const open = bind.enclosing_open(emitter, previous) orelse return false;
        if (!emitter.tokens[open].is_punctuation(.paren_open)) return false;
        if (!lambda_hung_call(emitter, open)) return false;
        return !lambda_mixed(emitter, open);
    }

    if (!emitter.tokens[position].is_punctuation(.paren_close)) return false;

    const open = emitter.brackets.open_of(position) orelse return false;
    return lambda_hung_call(emitter, open);
}

fn lambda_mixed(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.tokens[open].is_punctuation(.paren_open));

    const close = join.closing_of(emitter, open) orelse return false;
    var start = emit.ahead_of(emitter, open) orelse return false;
    var scan = start;

    for (0..core.list_item_max) |_| {
        if (scan >= close) return lambda_simple(emitter, start, scan);

        const token = emitter.tokens[scan];
        if (walk.is_open(token.kind)) return false;

        if (token.is_punctuation(.comma)) {
            if (!lambda_simple(emitter, start, scan)) return false;

            start = emit.ahead_of(emitter, scan) orelse return false;
        }

        scan = emit.ahead_of(emitter, scan) orelse return false;
    }

    return false;
}

fn lambda_simple(emitter: *const Emitter, start: u32, end: u32) bool {
    assert(start <= end);
    assert(end < emitter.count);

    if (start >= end) return true;

    var scan = start;

    for (0..lambda_prefix_max) |_| {
        if (!line.word_is(emitter, scan, lambda_prefixes)) break;

        scan = emit.ahead_of(emitter, scan) orelse return false;
    }

    const kind = emitter.tokens[scan].kind;
    const single = kind == .identifier or kind == .number or kind == .string or kind == .keyword;
    if (!single) return false;
    if (emit.ahead_of(emitter, scan) != end) return false;
    return flat_columns(emitter, start, end) <= lambda_short_max;
}

fn lambda_hung_call(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.tokens[open].is_punctuation(.paren_open));

    var head = open;

    for (0..core.type_scan_max) |_| {
        const back = emit.back_of(emitter, head) orelse break;
        if (!callee_word(emitter, back)) break;

        head = back;
    }

    if (head == open) return false;

    const end, const links, _ = chain_end(emitter, head);

    if (links != 0) return false;
    if (lambda_called(emitter, head, end) != open) return false;
    return lambda_hung(emitter, head);
}

fn lambda_called(emitter: *const Emitter, head: u32, end: u32) ?u32 {
    assert(head <= end);
    assert(end < emitter.count);

    if (!emitter.tokens[end].is_punctuation(.paren_close)) return null;

    const open = emitter.brackets.open_of(end) orelse return null;
    if (open <= head) return null;
    if (emit.ahead_of(emitter, open) == end) return null;

    var scan = head;

    while (scan < open) : (scan += 1) {
        const token = emitter.tokens[scan];
        if (token.length == 0) continue;
        if (token.kind == .newline) continue;
        if (!callee_word(emitter, scan)) return null;
    }

    return open;
}

pub fn lambda_hung_joined(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(previous < position);
    assert(position < emitter.count);

    if (!emitter.policy.call_budgets) return false;

    const prior = emitter.tokens[previous];
    const closing = emitter.tokens[position].is_punctuation(.paren_close);

    if (prior.is_punctuation(.paren_open)) return lambda_hung_nest(emitter, previous) != null;

    if (closing) {
        const shut = emitter.brackets.open_of(position) orelse return false;
        return lambda_hung_nest(emitter, shut) != null;
    }

    if (!prior.is_punctuation(.comma)) return false;

    const open = bind.enclosing_open(emitter, previous) orelse return false;
    if (!emitter.tokens[open].is_punctuation(.paren_open)) return false;

    const start = lambda_hung_list(emitter, open) orelse return false;
    return previous < start;
}

fn lambda_hung_nest(emitter: *const Emitter, open: u32) ?u32 {
    assert(open < emitter.count);

    if (!emitter.tokens[open].is_punctuation(.paren_open)) return null;
    return lambda_hung_list(emitter, sole_call(emitter, open));
}

fn lambda_hung_list(emitter: *const Emitter, open: u32) ?u32 {
    assert(open < emitter.count);

    if (!emitter.policy.call_budgets) return null;

    if (core.memo_found(emitter, .lambda_hung_list, open, 0)) |answer| {
        return if (answer == core.memo_none) null else answer;
    }

    const held = lambda_hung_list_scanned(emitter, open);

    core.memo_store(emitter, .lambda_hung_list, open, 0, held orelse core.memo_none);

    return held;
}

fn lambda_hung_list_scanned(emitter: *const Emitter, open: u32) ?u32 {
    assert(open < emitter.count);
    assert(emitter.policy.call_budgets);

    const close = join.closing_of(emitter, open) orelse return null;
    if (close <= open + 1) return null;

    const head = lambda_last_body(emitter, open, close) orelse return null;
    if (!lambda_hung(emitter, head)) return null;
    return lambda_start(emitter, head);
}

fn lambda_last_body(emitter: *const Emitter, open: u32, close: u32) ?u32 {
    assert(open + 1 < close);
    assert(close < emitter.count);

    var depth: u32 = 0;
    var params = false;
    var prior: ?u32 = null;
    var found: ?u32 = null;
    var scan = open + 1;

    while (scan < close) : (scan += 1) {
        const token = emitter.tokens[scan];

        if (walk.is_open(token.kind)) {
            depth += 1;
        } else if (walk.is_close(token.kind)) {
            depth -|= 1;
        } else if (depth == 0) {
            if (token.is_punctuation(.comma)) {
                if (!params) found = null;
            }

            const opens = operand_opens(emitter, prior);
            const doubled = text_is(emitter, scan, "||") and opens;
            const singled = text_is(emitter, scan, "|") and (params or opens);

            if (doubled) found = emit.ahead_of(emitter, scan);

            if (singled) {
                params = !params;

                if (!params) found = emit.ahead_of(emitter, scan);
            }
        } else {}

        if (token.length > 0) prior = scan;
    }

    if (found) |held| assert(held > open);

    return found;
}

fn lambda_start(emitter: *const Emitter, head: u32) ?u32 {
    assert(head < emitter.count);

    const bar = emit.back_of(emitter, head) orelse return null;
    var start = bar;

    if (!text_is(emitter, bar, "||")) {
        if (!text_is(emitter, bar, "|")) return null;

        start = lambda_bar_open(emitter, bar) orelse return null;
    }

    const before = emit.back_of(emitter, start) orelse return null;

    if (text_is(emitter, before, "move")) start = before;

    const argued = emit.back_of(emitter, start) orelse return null;
    const token = emitter.tokens[argued];

    assert(start < head);

    if (token.is_punctuation(.paren_open)) return start;
    if (token.is_punctuation(.comma)) return start;
    return null;
}

fn lambda_bar_open(emitter: *const Emitter, bar: u32) ?u32 {
    assert(bar < emitter.count);

    var depth: u32 = 0;
    var scan = bar;

    for (0..core.define_scan_max) |_| {
        const held = emit.back_of(emitter, scan) orelse return null;
        const kind = emitter.tokens[held].kind;

        assert(held < scan);

        if (walk.is_close(kind)) {
            depth += 1;
        } else if (walk.is_open(kind)) {
            if (depth == 0) return null;

            depth -= 1;
        } else if (depth == 0) {
            if (text_is(emitter, held, "|")) return held;
        } else {}

        scan = held;
    }

    return null;
}

fn lambda_macroed(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    var scan = open;

    for (0..brace.nest_depth_max) |_| {
        if (emitter.tokens[scan].kind == .block_start) return false;

        if (emit.back_of(emitter, scan)) |held| {
            if (emitter.tokens[held].is_punctuation(.bang)) return true;
        }

        scan = bind.enclosing_open(emitter, scan) orelse return false;
    }

    return false;
}

fn lambda_closes(emitter: *const Emitter, end: u32, close: u32) bool {
    assert(end < close);
    assert(close < emitter.count);

    const next = emit.ahead_of(emitter, end) orelse return false;
    if (next == close) return true;
    if (!emitter.tokens[next].is_punctuation(.comma)) return false;
    return emit.ahead_of(emitter, next) == close;
}

fn lambda_budget(emitter: *const Emitter, open: u32, start: u32) ?u32 {
    assert(open < start);
    assert(start < emitter.count);

    const lead = emit.ahead_of(emitter, open) orelse return null;
    const before: u32 = if (lead == start) 0 else flat_columns(emitter, lead, start) + 2;
    var inner = open;
    var spent: u32 = 0;

    for (0..brace.nest_depth_max) |_| {
        const outer = bind.enclosing_open(emitter, inner) orelse break;
        if (emitter.tokens[outer].kind == .block_start) break;
        if (sole_inner(emitter, outer) != inner) break;

        spent += callee_columns(emitter, inner) + 2;
        inner = outer;
    }

    if (spent + before == 0) return null;
    const returned = emitter.policy.call_width -| (spent + before);

    assert(returned < std.math.maxInt(u32));

    return returned;
}

fn listed_broken(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    if (element_count(emitter, open, close) < 2) return false;
    if (hugged_point(emitter, open, close) != null) return false;

    var scan = open + 1;

    while (scan < close) : (scan += 1) {
        if (spans_wide(emitter, scan)) return true;
    }

    return false;
}

fn spans_wide(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    const kind = emitter.tokens[open].kind;
    const opens = walk.is_open(kind) or kind == .block_start;
    if (!opens) return false;

    const close = join.closing_of(emitter, open) orelse return false;

    assert(open < close);

    if (kind == .block_start) return spans_wide_brace(emitter, open, close);
    if (!sole.listed(emitter, close)) return false;

    const held = sole_call(emitter, open);
    const stop = join.closing_of(emitter, held) orelse return false;
    const nested = emitter.policy.call_nests;
    const measured = if (nested) open else held;
    const ends = if (nested) close else stop;
    const from = emitter.tokens[measured].end();
    const to = emitter.tokens[ends].offset;
    if (walk.columns(emitter.source, from, to) <= emitter.policy.call_width) return false;
    return elemental_list(emitter, held, stop);
}

fn spans_wide_brace(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(emitter.tokens[open].kind == .block_start);

    if (!valued_brace(emitter, open)) return false;

    const lead = emit.ahead_of(emitter, open) orelse return false;
    const tail = emit.back_of(emitter, close) orelse return false;
    const inside = lead <= tail;
    const from = if (inside) emitter.tokens[lead].offset else emitter.tokens[open].end();
    const to = if (inside) emitter.tokens[tail].end() else emitter.tokens[close].offset;

    return walk.columns(emitter.source, from, to) > literal_bound(emitter, open);
}

fn stringed_wide(emitter: *const Emitter, open: u32, close: u32, rooted_close: bool) bool {
    assert(open < close);
    assert(close < emitter.count);

    if (rooted_close) return false;
    if (linked_bracket(emitter, open)) return false;

    const lead = emit.ahead_of(emitter, open) orelse return false;
    if (lead >= close) return false;
    if (emitter.tokens[lead].kind != .string) return false;
    if (emit.ahead_of(emitter, lead) != close) return false;

    const head = statement_word(emitter, open) orelse return false;
    const end = statement_close(emitter, close);
    const under = emitter.printed * emitter.options.indent_width;
    const lined = emitter.line_first > head and emitter.line_first < open;

    if (lined) {
        const after = emit.ahead_of(emitter, close) orelse close;
        const tail = if (emitter.tokens[after].is_punctuation(.comma)) after else close;
        const spelled = flat_columns(emitter, emitter.line_first, tail + 1);

        return under + spelled > emitter.options.line_width;
    }

    if (assigned_value(emitter, head, open)) |value| {
        const indent = indent_of(emitter, head) + emitter.options.indent_width;
        const flat = indent + flat_columns(emitter, value, end + 1);
        if (flat <= emitter.options.line_width) return false;
    }

    return under + flat_columns(emitter, head, end + 1) > emitter.options.line_width;
}

fn assigned_value(emitter: *const Emitter, head: u32, stop: u32) ?u32 {
    assert(head < emitter.count);
    assert(stop < emitter.count);

    var depth: u32 = 0;
    var scan = head;

    while (scan < stop) : (scan += 1) {
        const kind = emitter.tokens[scan].kind;

        if (walk.is_open(kind)) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            depth -|= 1;
        } else if (depth == 0) {
            if (text_is(emitter, scan, "=")) return emit.ahead_of(emitter, scan);
        } else {}
    }

    return null;
}

fn comma_mixed(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    const lead = emit.ahead_of(emitter, open) orelse return false;
    if (lead >= close) return false;
    if (body.parts_at(emitter, open, lead)) return false;

    var walker = list_commas(emitter, open, close);

    for (open + 1..close) |_| {
        const comma = walker.step(emitter) orelse break;
        const ahead = emit.ahead_of(emitter, comma) orelse continue;
        if (body.parts_at(emitter, comma, ahead)) return true;
    }

    return false;
}

fn comma_commented(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    var walker = list_commas(emitter, open, close);

    for (open + 1..close) |_| {
        const comma = walker.step(emitter) orelse break;
        const ahead = emit.ahead_of(emitter, comma) orelse continue;
        const token = emitter.tokens[ahead];
        if (token.kind != .comment) continue;
        if (std.mem.startsWith(u8, token.text(emitter.source), "//")) return true;
    }

    return false;
}

fn list_commas(emitter: *const Emitter, open: u32, close: u32) ListCommas {
    assert(open < close);
    assert(close < emitter.count);

    return .{
        .close = close,
        .depth = 0,
        .lambda = false,
        .prior = null,
        .scan = open + 1,
    };
}

fn linked_wide(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    if (emitter.policy.chain_width == 0) return false;

    const callee = emit.back_of(emitter, open) orelse return false;
    const dot = emit.back_of(emitter, callee) orelse return false;
    if (!dotted(emitter, dot)) return false;

    const head = chain_head(emitter, dot);
    const end, const links, _ = chain_end(emitter, head);

    if (links < 1) return false;

    const from = emitter.tokens[head].offset;
    const to = emitter.tokens[end].end();
    if (body.parted_by(emitter, from, to) == 0) return false;

    const under = chained_indent(emitter, head) + emitter.options.indent_width;

    if (!link_blocked(emitter, head, end)) {
        return under + flat_columns(emitter, dot, close + 1) > emitter.options.line_width;
    }

    const tail = link_tail(emitter, close, end);
    const margin = if (tail == end) chain_margin(emitter, end) else 0;
    const seat = under - emitter.options.indent_width;

    return seat + flat_columns(emitter, dot, tail + 1) + margin > emitter.options.line_width;
}

fn link_tail(emitter: *const Emitter, close: u32, end: u32) u32 {
    assert(close <= end);
    assert(end < emitter.count);

    var tail = close;

    while (tail < end) {
        const ahead = emit.ahead_of(emitter, tail) orelse break;
        if (ahead > end) break;
        if (!text_is(emitter, ahead, "?")) break;

        tail = ahead;
    }

    return tail;
}

fn link_blocked(emitter: *const Emitter, head: u32, end: u32) bool {
    assert(head <= end);
    assert(end < emitter.count);

    const first = linked_first(emitter, head, end);
    if (first > end) return false;

    const close = emit.back_of(emitter, first) orelse return false;
    const open = emitter.brackets.open_of(close) orelse return false;
    if (open < head) return false;

    const inside = emitter.tokens[open].end();
    if (body.parted_by(emitter, inside, emitter.tokens[close].offset) == 0) return false;

    const kind = emitter.tokens[open].kind;
    const before = emit.back_of(emitter, open) orelse return open == head;
    const callee = before >= head;

    if (kind.eql(.{ .punctuation = .bracket_open })) {
        return open == head or emitter.tokens[before].is_punctuation(.bang);
    }

    if (!callee) return false;
    if (kind == .block_start) return emitter.tokens[before].kind == .identifier;

    if (kind.eql(.{ .punctuation = .paren_open })) {
        if (emitter.tokens[before].is_punctuation(.bang)) return true;
        if (emitter.tokens[before].is_punctuation(.greater)) return true;
        return walk.ends_operand(emitter.tokens[before].kind);
    }

    return false;
}

fn tailed_close(emitter: *const Emitter, ends: u32, measured: u32) bool {
    assert(ends < emitter.count);
    assert(measured < emitter.count);

    const tail = emit.back_of(emitter, ends) orelse return false;
    if (tail <= measured) return false;
    return emitter.tokens[tail].is_punctuation(.comma);
}

pub fn sole_budget(emitter: *const Emitter, open: u32) u32 {
    assert(open < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    const call_width = emitter.policy.call_width;
    if (!emitter.policy.call_budgets) return call_width;
    if (emitter.depth == 0) return call_width;

    var budget = call_width;

    for (0..emitter.depth - 1) |level| {
        const frame = emitter.nest[level];
        const held = emitter.nest[level + 1];
        if (held.open > open) break;

        const width = callee_columns(emitter, held.open) + 2;
        const linked = linked_bracket(emitter, frame.open);
        const base = if (linked) call_width else budget;
        const called = sole_framed(emitter, &frame) and sole_framed(emitter, &held);
        const inner = if (called) sole_inner(emitter, frame.open) else null;
        const nested = inner == held.open and width <= base;

        budget = if (nested) base - width else call_width;
    }

    return budget;
}

pub fn bound_patterned(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.tokens[open].is_punctuation(.paren_open)) return false;
    if (bound_typed(emitter, open)) return true;

    var outer = open;
    var scan = open;

    for (0..core.type_scan_max) |_| {
        const held = emit.back_of(emitter, scan) orelse return false;
        const token = emitter.tokens[held];

        assert(held < scan);

        if (token.kind == .block_start) return false;
        if (token.kind == .block_end) return false;

        if (walk.is_close(token.kind)) {
            scan = emitter.brackets.open_of(held) orelse return false;

            continue;
        }

        if (walk.is_open(token.kind)) {
            if (bound_typed(emitter, held)) return true;

            outer = held;
        } else {
            if (text_is(emitter, held, "let")) return true;

            if (text_is(emitter, held, "for")) {
                const close = join.closing_of(emitter, outer) orelse return false;
                const after = emit.ahead_of(emitter, close) orelse return false;

                return text_is(emitter, after, "in");
            }

            if (text_is(emitter, held, "|")) {
                return operand_opens(emitter, emit.back_of(emitter, held));
            }

            if (bound_stops(emitter, held)) return false;
        }

        scan = held;
    }

    return false;
}

fn bound_fits(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    const flat = flat_columns(emitter, open, close + 1) + bound_tail(emitter, close);
    return spread_of(emitter, open) + flat <= emitter.options.line_width;
}

fn bound_tail(emitter: *const Emitter, close: u32) u32 {
    assert(close < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var tail: u32 = 0;
    var scan = close;

    for (0..core.type_scan_max) |_| {
        const held = emit.ahead_of(emitter, scan) orelse return tail;
        const token = emitter.tokens[held];

        if (walk.is_close(token.kind)) {
            tail += 1;
            scan = held;

            continue;
        }

        if (text_is(emitter, held, "=")) {
            assert(tail + 2 <= emitter.count);

            return tail + 2;
        }

        if (text_is(emitter, held, "in")) {
            assert(tail + 3 <= emitter.count);

            return tail + 3;
        }

        if (token.is_punctuation(.colon)) {
            assert(tail + 1 <= emitter.count);

            return tail + 1;
        }

        if (!text_is(emitter, held, "|")) return tail;

        const after = emit.ahead_of(emitter, held) orelse {
            assert(tail + 1 <= emitter.count);

            return tail + 1;
        };
        const braced = emitter.tokens[after].kind == .block_start;

        assert(tail + 1 + @as(u32, if (braced) 2 else 1) <= emitter.count);

        return tail + 1 + @as(u32, if (braced) 2 else 1);
    }

    return tail;
}

fn bound_typed(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    if (!emitter.tokens[open].is_punctuation(.paren_open)) return false;

    const close = join.closing_of(emitter, open) orelse return false;
    const after = emit.ahead_of(emitter, close) orelse return false;
    if (!emitter.tokens[after].is_punctuation(.colon)) return false;

    const before = emit.back_of(emitter, open) orelse return false;
    const token = emitter.tokens[before];
    if (token.is_punctuation(.paren_open)) return true;
    if (token.is_punctuation(.comma)) return true;
    return text_is(emitter, before, "|");
}

fn bound_stops(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    const token = emitter.tokens[position];
    if (token.is_punctuation(.semicolon)) return true;
    if (token.is_punctuation(.colon)) return true;
    if (token.is_punctuation(.assign)) return true;
    if (text_is(emitter, position, "=")) return true;
    if (text_is(emitter, position, "=>")) return true;
    if (text_is(emitter, position, "in")) return true;
    return text_is(emitter, position, "return");
}

fn arm_patterned(emitter: *const Emitter, close: u32) bool {
    assert(close < emitter.count);

    if (emitter.brackets.open_of(close)) |open| {
        if (guard_behind(emitter, open)) return false;
    }

    var depth: u32 = 0;
    var scan = close;

    for (0..core.type_scan_max) |_| {
        const held = emit.ahead_of(emitter, scan) orelse return false;
        const kind = emitter.tokens[held].kind;
        const opens = walk.is_open(kind) or kind == .block_start;
        const closes = walk.is_close(kind) or kind == .block_end;

        assert(held > scan);

        if (opens) {
            depth += 1;
        } else if (closes) {
            if (depth == 0) return false;

            depth -= 1;
        } else if (depth == 0) {
            if (text_is(emitter, held, "=>")) return true;
            if (separating(emitter, held)) return false;
        } else {}

        scan = held;
    }

    return false;
}

pub fn chain_parted_dot(emitter: *const Emitter, from: u32, to: u32) ?u32 {
    assert(from <= to);
    assert(to < emitter.count);

    var depth: u32 = 0;
    var scan = from;

    while (scan < to) : (scan += 1) {
        const kind = emitter.tokens[scan].kind;
        const opens = walk.is_open(kind) or kind == .block_start;
        const closes = walk.is_close(kind) or kind == .block_end;

        if (opens) {
            depth += 1;
        } else if (closes) {
            depth -|= 1;
        } else {
            const dotting = depth == 0 and scan > from and dotted(emitter, scan);

            if (dotting) {
                const before = emit.back_of(emitter, scan) orelse return null;
                if (body.parts_at(emitter, before, scan)) return before;
            }
        }
    }

    return null;
}

pub fn chain_spread(emitter: *const Emitter, position: u32, last: u32) ?u32 {
    assert(position < last);
    assert(last < emitter.count);

    if (!emitter.policy.call_budgets) return null;

    const tail = hug_link(emitter, position, last);
    const open = opened_after(emitter, tail, last) orelse return null;
    const close = join.closing_of(emitter, open) orelse return null;
    const from = emitter.tokens[position].offset;
    if (body.parted_by(emitter, from, emitter.tokens[open].end()) > 0) return null;
    if (braced_after(emitter, open, close) != null) return null;

    for (open + 1..close) |index| {
        if (text_is(emitter, @intCast(index), "|")) return null;
        if (text_is(emitter, @intCast(index), "||")) return null;
    }

    const returned = flat_columns(emitter, position, last + 1);

    assert(returned < std.math.maxInt(u32));

    return returned;
}

pub fn logic_parted(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(previous < position);
    assert(position < emitter.count);

    if (!emitter.policy.call_budgets) return false;

    const kind = emitter.tokens[position].kind;
    const anded = kind.eql(.{ .punctuation = .ampersand_double });
    const ored = kind.eql(.{ .punctuation = .bar_double });

    if (!anded) {
        if (!ored) return false;
    }

    if (emitter.tokens[previous].kind.eql(.{ .punctuation = .ampersand_double })) return false;
    if (!logic_operand(emitter, previous)) return false;

    const start = logic_start(emitter, previous) orelse return false;
    const end = logic_end(emitter, position) orelse return false;
    if (!logic_single(emitter, start, end)) return false;
    return binary_chained(emitter, start, end);
}

fn logic_operand(emitter: *const Emitter, previous: u32) bool {
    assert(previous < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const kind = emitter.tokens[previous].kind;
    if (walk.ends_operand(kind)) return true;
    if (kind == .keyword) return true;
    return text_is(emitter, previous, "?");
}

fn logic_start(emitter: *const Emitter, previous: u32) ?u32 {
    assert(previous < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var depth: u32 = 0;
    var start = previous;
    var scan = previous;

    for (0..core.type_scan_max) |_| {
        const kind = emitter.tokens[scan].kind;

        if (walk.is_close(kind)) {
            depth += 1;
        } else if (walk.is_open(kind)) {
            if (depth == 0) return start;

            depth -= 1;
        } else if (depth == 0) {
            if (line.word_is(emitter, scan, logic_stops)) return start;
        } else {}

        start = scan;
        scan = emit.back_of(emitter, scan) orelse return null;
    }

    return null;
}

fn logic_end(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var depth: u32 = 0;
    var end = position;
    var scan = position;

    for (0..core.type_scan_max) |_| {
        const kind = emitter.tokens[scan].kind;

        if (depth == 0) {
            if (kind == .block_start) return end;
        }

        if (walk.is_open(kind)) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            if (depth == 0) return end;

            depth -= 1;
        } else if (depth == 0) {
            if (line.word_is(emitter, scan, logic_stops)) return end;
        } else {}

        end = scan;
        scan = emit.ahead_of(emitter, scan) orelse return null;
    }

    return null;
}

fn logic_single(emitter: *const Emitter, start: u32, end: u32) bool {
    assert(start <= end);
    assert(end < emitter.count);

    var anded = false;
    var ored = false;
    var depth: u32 = 0;
    var scan = start;

    while (scan <= end) : (scan += 1) {
        const kind = emitter.tokens[scan].kind;
        const opens = walk.is_open(kind) or kind == .block_start;
        const closes = walk.is_close(kind) or kind == .block_end;

        if (opens) {
            depth += 1;
        } else if (closes) {
            depth -|= 1;
        } else if (depth == 0) {
            anded = anded or kind.eql(.{ .punctuation = .ampersand_double });
            ored = ored or kind.eql(.{ .punctuation = .bar_double });
        } else {}
    }

    return anded != ored;
}

fn binary_chained(emitter: *const Emitter, head: u32, stop: u32) bool {
    assert(head <= stop);
    assert(stop < emitter.count);

    var depth: u32 = 0;
    var scan = head;

    for (0..core.type_scan_max) |_| {
        if (scan >= stop) return false;

        const kind = emitter.tokens[scan].kind;
        const opens = walk.is_open(kind) or kind == .block_start;
        const closes = walk.is_close(kind) or kind == .block_end;

        if (opens) {
            depth += 1;
        } else if (closes) {
            depth -|= 1;
        } else if (depth == 0) {
            if (dotted(emitter, scan)) {
                if (binary_chain_over(emitter, head, scan, stop)) return true;
            }
        } else {}

        scan = emit.ahead_of(emitter, scan) orelse return false;
    }

    return false;
}

fn binary_chain_over(emitter: *const Emitter, head: u32, dot: u32, stop: u32) bool {
    assert(head < dot);
    assert(dot <= stop);

    const root = chain_head(emitter, dot);
    if (root < head) return false;

    const end, const links, _ = chain_end(emitter, root);

    if (links < 2) return false;
    if (end > stop) return false;
    return chained_over_flat(emitter, root, end);
}

pub fn bar_parted(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(previous < position);
    assert(position < emitter.count);

    if (!emitter.policy.arm_guards) return false;
    if (!text_is(emitter, position, "|")) return false;
    if (emitter.depth == 0) return false;
    if (emitter.nest[emitter.depth - 1].kind != .block_start) return false;

    const kind = emitter.tokens[previous].kind;

    if (!walk.is_close(kind)) {
        if (kind != .block_end) return false;
    }

    const open = emitter.brackets.open_of(previous) orelse return false;
    if (open >= emitter.line_first) return false;
    if (open < emitter.nest[emitter.depth - 1].open) return false;
    return arm_patterned(emitter, previous);
}

pub fn arm_owed(emitter: *const Emitter, close: u32) u32 {
    assert(close < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.arm_guards) return 0;

    var scan = close;

    for (0..brace.nest_depth_max) |_| {
        const next = emit.ahead_of(emitter, scan) orelse return 0;

        if (!walk.is_close(emitter.tokens[next].kind)) {
            return if (text_is(emitter, next, "=>")) arm_arrow_owed else 0;
        }

        scan = next;
    }

    return 0;
}

fn guard_behind(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    var depth: u32 = 0;
    var scan = open;

    for (0..core.type_scan_max) |_| {
        const held = emit.back_of(emitter, scan) orelse return false;
        const kind = emitter.tokens[held].kind;
        const closes = walk.is_close(kind) or kind == .block_end;
        const opens = walk.is_open(kind) or kind == .block_start;

        assert(held < scan);

        if (closes) {
            depth += 1;
        } else if (opens) {
            if (depth == 0) return false;

            depth -= 1;
        } else if (depth == 0) {
            if (text_is(emitter, held, "if")) return true;
            if (text_is(emitter, held, "=>")) return false;
            if (separating(emitter, held)) return false;
        } else {}

        scan = held;
    }

    return false;
}

fn separating(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    const token = emitter.tokens[position];
    if (token.is_punctuation(.comma)) return true;
    return token.is_punctuation(.semicolon);
}

pub fn element_count(emitter: *const Emitter, open: u32, close: u32) u32 {
    assert(open < emitter.count);
    assert(close < emitter.count);

    if (core.memo_found(emitter, .element_count, open, close)) |answer| return answer;

    const held = element_count_scanned(emitter, open, close);

    core.memo_store(emitter, .element_count, open, close, held);

    return held;
}

fn element_count_scanned(emitter: *const Emitter, open: u32, close: u32) u32 {
    assert(open < emitter.count);
    assert(close <= emitter.count);

    var elements: u32 = 1;
    var depth: u32 = 0;
    var scan = open + 1;

    while (scan < close) {
        if (tmpl.template_body(emitter, scan)) |end| {
            assert(end >= scan);

            scan = end + 1;

            continue;
        }

        const kind = emitter.tokens[scan].kind;
        const opens = walk.is_open(kind) or kind == .block_start;
        const closes = walk.is_close(kind) or kind == .block_end;
        const separates = depth == 0 and emitter.tokens[scan].is_punctuation(.comma);

        if (opens) {
            depth += 1;
        } else if (closes) {
            depth -|= 1;
        } else if (separates) {
            if (!closure.barred(emitter, scan)) {
                if (emit.ahead_of(emitter, scan) != close) elements += 1;
            }
        } else {}

        scan += 1;
    }

    assert(elements >= 1);

    return elements;
}

pub fn elemental_list(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    const patterned = elemental_patterned(emitter, open, close);
    var depth: u32 = 0;
    var elements: u32 = 1;
    var scan = open + 1;

    while (scan < close) : (scan += 1) {
        const token = emitter.tokens[scan];

        if (token.kind == .comment) {
            if (!emitter.policy.list_comments) return false;
            if (!std.mem.startsWith(u8, token.text(emitter.source), "/*")) return false;
        }

        const opens = walk.is_open(token.kind) or token.kind == .block_start;
        const closes = walk.is_close(token.kind) or token.kind == .block_end;

        if (opens) {
            depth += 1;

            continue;
        }

        if (closes) {
            depth -|= 1;

            continue;
        }

        if (depth > 0) continue;

        if (text_is(emitter, scan, "|")) {
            if (patterned) return false;
            if (lambda_bars(emitter, open, scan)) return false;
        }

        if (!token.is_punctuation(.comma)) continue;
        if (elemental_angled(emitter, open, scan)) continue;

        if (emit.ahead_of(emitter, scan) != close) elements += 1;
    }

    return elements > 1;
}

fn elemental_angled(emitter: *const Emitter, open: u32, comma: u32) bool {
    assert(open < comma);
    assert(comma < emitter.count);

    if (emitter.brackets.angles_at(comma) <= emitter.brackets.angles_at(open)) return false;
    return join.angle_head(emitter, comma) != null;
}

fn elemental_patterned(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    if (emit.ahead_of(emitter, close)) |held| {
        if (text_is(emitter, held, "=>")) return true;
    }

    const bang = emit.word_before(emitter, open) orelse return false;
    const name = emit.word_before(emitter, bang) orelse return false;
    if (!text_is(emitter, name, "matches")) return false;
    return ranged_list(emitter, open, close);
}

fn ranged_list(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    var depth: u32 = 0;
    var scan = open + 1;

    while (scan < close) : (scan += 1) {
        const kind = emitter.tokens[scan].kind;
        const opens = walk.is_open(kind) or kind == .block_start;
        const closes = walk.is_close(kind) or kind == .block_end;

        if (opens) {
            depth += 1;
        } else if (closes) {
            depth -|= 1;
        } else if (depth == 0) {
            if (emit.ranges(emitter, scan)) return true;
        } else {}
    }

    return false;
}

pub fn lambda_sole(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    var depth: u32 = 0;
    var lambda = false;
    var prior: ?u32 = null;
    var scan = open + 1;

    while (scan < close) : (scan += 1) {
        const token = emitter.tokens[scan];
        const opens = walk.is_open(token.kind) or token.kind == .block_start;
        const closes = walk.is_close(token.kind) or token.kind == .block_end;

        if (opens) {
            depth += 1;
        } else if (closes) {
            depth -|= 1;
        } else if (depth == 0) {
            const operand = lambda or operand_opens(emitter, prior);

            if (text_is(emitter, scan, "|")) {
                if (operand) lambda = !lambda;
            }

            const separates = token.is_punctuation(.comma) and !lambda;

            if (separates) {
                if (emit.ahead_of(emitter, scan) != close) return false;
            }
        } else {}

        if (token.length > 0) prior = scan;
    }

    return true;
}

fn lambda_bars(emitter: *const Emitter, open: u32, position: u32) bool {
    assert(open < position);
    assert(position < emitter.count);

    var lambda = false;
    var prior: ?u32 = null;

    for (open + 1..open + 1 + core.define_scan_max) |index| {
        const scan: u32 = @intCast(index);
        if (scan > position) return false;
        if (scan >= emitter.count) return false;

        const token = emitter.tokens[scan];
        const opens = operand_opens(emitter, prior);
        const toggles = text_is(emitter, scan, "|") and (lambda or opens);

        if (toggles) {
            if (scan == position) return true;

            lambda = !lambda;
        }

        if (token.length > 0) prior = scan;
    }

    return false;
}

pub fn inner_blank(emitter: *const Emitter, position: u32, prior: u32) bool {
    assert(position < emitter.count);
    assert(prior < emitter.count);

    if (emitter.depth > 0) return false;
    if (inner_documented(emitter, position)) return false;
    if (inner_documented(emitter, prior)) return false;

    if (inner_ends(emitter, prior)) {
        if (inner_ahead(emitter, position)) return true;
    }

    if (!inner_opens(emitter, position)) return false;
    return inner_behind(emitter, prior);
}

fn inner_documented(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    if (emitter.tokens[position].kind != .comment) return false;

    const text = emitter.tokens[position].text(emitter.source);
    return std.mem.startsWith(u8, text, "//!") or std.mem.startsWith(u8, text, "/*!");
}

fn inner_ends(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    if (!emitter.tokens[position].is_punctuation(.bracket_close)) return false;

    const open = emitter.brackets.open_of(position) orelse return false;

    assert(open < position);

    return inner_hashed(emitter, open);
}

fn inner_opens(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    if (text_is(emitter, position, "#!")) return true;
    if (!text_is(emitter, position, "#")) return false;

    const held = emit.ahead_of(emitter, position) orelse return false;

    assert(held > position);

    return text_is(emitter, held, "!");
}

fn inner_ahead(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    var scan = position;

    for (0..core.type_scan_max) |_| {
        assert(scan >= position);

        if (inner_opens(emitter, scan)) return true;
        if (emitter.tokens[scan].kind != .comment) return false;

        scan = emit.ahead_of(emitter, scan) orelse return false;
    }

    return false;
}

fn inner_behind(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    var scan = position;

    for (0..core.type_scan_max) |_| {
        assert(scan <= position);

        if (inner_ends(emitter, scan)) return true;
        if (emitter.tokens[scan].kind != .comment) return false;

        scan = emit.back_of(emitter, scan) orelse return false;
    }

    return false;
}

fn inner_hashed(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    const held = emit.back_of(emitter, open) orelse return false;

    assert(held < open);

    if (text_is(emitter, held, "#!")) return true;
    if (!text_is(emitter, held, "!")) return false;

    const hash = emit.back_of(emitter, held) orelse return false;
    return text_is(emitter, hash, "#");
}

pub fn indent_of(emitter: *const Emitter, position: u32) u32 {
    assert(position < emitter.count);

    const start = opened_at(emitter, position);
    var stop = start;

    while (stop < emitter.source.len) : (stop += 1) {
        const byte = emitter.source[stop];
        const blank = byte == ' ' or byte == '\t';
        if (!blank) break;
    }

    assert(stop >= start);

    return tabbed(emitter, start, stop);
}

fn opened_at(emitter: *const Emitter, position: u32) usize {
    assert(position < emitter.count);

    var start: usize = emitter.tokens[position].offset;

    assert(start <= emitter.source.len);

    while (start > 0) : (start -= 1) {
        if (emitter.source[start - 1] == '\n') break;
    }

    return start;
}

fn tabbed(emitter: *const Emitter, from: usize, to: usize) u32 {
    assert(from <= to);
    assert(to <= emitter.source.len);

    var tabs: u32 = 0;

    for (emitter.source[from..to]) |byte| {
        tabs += @intFromBool(byte == '\t');
    }

    const spelled = walk.columns(emitter.source, @intCast(from), @intCast(to));
    const returned = spelled + tabs * (emitter.options.indent_width -| 1);

    assert(returned < std.math.maxInt(u32));

    return returned;
}

fn lined_of(emitter: *const Emitter, position: u32) u32 {
    assert(position < emitter.count);

    var stop: usize = emitter.tokens[position].offset;

    assert(stop <= emitter.source.len);

    while (stop < emitter.source.len) : (stop += 1) {
        if (emitter.source[stop] == '\n') break;
    }

    return tabbed(emitter, opened_at(emitter, position), stop);
}

fn spread_of(emitter: *const Emitter, position: u32) u32 {
    assert(position < emitter.count);
    assert(emitter.tokens[position].offset <= emitter.source.len);

    return tabbed(emitter, opened_at(emitter, position), emitter.tokens[position].offset);
}

fn leading(emitter: *const Emitter, position: u32) u32 {
    assert(position < emitter.count);

    const offset = opened_at(emitter, position);
    var held = offset;

    while (held < emitter.source.len) : (held += 1) {
        const byte = emitter.source[held];
        const blank = byte == ' ' or byte == '\t';
        if (!blank) break;
    }

    assert(held >= offset);

    return @intCast(held - offset);
}

fn heads_line(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    const head = opened_at(emitter, position);
    const from = @min(emitter.tokens[position].offset, emitter.source.len);

    assert(head <= from);

    for (emitter.source[head..from]) |byte| {
        const blank = byte == ' ' or byte == '\t';
        if (!blank) return false;
    }

    return true;
}

fn head_column(emitter: *const Emitter, head: u32) ?u32 {
    assert(head < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const lead = statement_word(emitter, head) orelse return null;
    if (lead >= head) return null;

    if (!text_is(emitter, lead, "return")) {
        if (assigned_value(emitter, lead, head) != head) return null;
    }

    const returned = chained_indent(emitter, head) + flat_columns(emitter, lead, head) + 1;

    assert(returned < std.math.maxInt(u32));

    return returned;
}

fn chained_at(emitter: *const Emitter, head: u32) u32 {
    assert(head < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (assign_seated(emitter, head)) {
        const returned = chained_indent(emitter, head) + emitter.options.indent_width;

        assert(returned < std.math.maxInt(u32));

        return returned;
    }

    if (lined_of(emitter, head) > emitter.options.line_width) {
        const column = head_column(emitter, head) orelse
            chained_indent(emitter, head) + emitter.options.indent_width;

        assert(column < std.math.maxInt(u32));

        return column;
    }

    return spread_of(emitter, head);
}

fn chained_seat(emitter: *const Emitter, head: u32) u32 {
    assert(head < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    return argued_seat(emitter, head) orelse chained_at(emitter, head);
}

fn argued_seat(emitter: *const Emitter, head: u32) ?u32 {
    assert(head < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const open = emit.back_of(emitter, head) orelse return null;
    if (!emitter.tokens[open].is_punctuation(.paren_open)) return null;
    if (body.parts_at(emitter, open, head)) return null;

    const close = join.closing_of(emitter, open) orelse return null;
    if (!chained_sole(emitter, open, close)) return null;

    const held = sole_call(emitter, open);
    if (held != open) return null;
    if (listed_soled(emitter, open, close, held) == null) return null;
    const returned = opened_seat(emitter, open) + emitter.options.indent_width;

    assert(returned < std.math.maxInt(u32));

    return returned;
}

fn opened_seat(emitter: *const Emitter, open: u32) u32 {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var first = open;

    for (0..core.type_scan_max) |_| {
        if (heads_line(emitter, first)) break;

        first = emit.back_of(emitter, first) orelse break;
    }

    const before = emit.back_of(emitter, first) orelse return indent_of(emitter, open);
    if (text_is(emitter, before, "=")) return chained_indent(emitter, open);
    if (opened_arm(emitter, before, open)) return indent_of(emitter, before);
    return indent_of(emitter, open);
}

fn opened_arm(emitter: *const Emitter, curly: u32, open: u32) bool {
    assert(curly < open);
    assert(open < emitter.count);

    if (emitter.tokens[curly].kind != .block_start) return false;

    const arrow = emit.back_of(emitter, curly) orelse return false;
    if (!text_is(emitter, arrow, "=>")) return false;

    const close = join.closing_of(emitter, open) orelse return false;
    const after = emit.ahead_of(emitter, close) orelse return false;

    return emitter.brackets.open_of(after) == curly;
}

pub fn flat_columns(emitter: *const Emitter, from: u32, to: u32) u32 {
    assert(emitter.count <= emitter.tokens.len);
    assert(from < emitter.count);
    assert(to <= emitter.count);

    var prior: ?u32 = null;
    var scan = from;
    var spelled: u32 = 0;

    while (scan < to) : (scan += 1) {
        if (scan >= emitter.count) break;

        const token = emitter.tokens[scan];
        if (token.length == 0) continue;
        if (token.kind == .newline) continue;

        const welded = commas(emitter, scan) and closes_after(emitter, scan, to);
        if (welded) continue;

        const gapped = if (prior) |before| flat_columns_gapped(emitter, before, scan) else false;

        spelled += @intFromBool(gapped) + walk.columns(emitter.source, token.offset, token.end());
        prior = scan;
    }

    if (from >= to) assert(spelled == 0);

    return spelled;
}

fn flat_columns_gapped(emitter: *const Emitter, before: u32, scan: u32) bool {
    assert(before < scan);
    assert(scan < emitter.count);

    const tight = tight_pair(emitter, before, scan);
    const welded = tight and !comment.header_semi_gap(emitter, before, scan);
    const apart = emitter.tokens[before].end() < emitter.tokens[scan].offset;
    const spaced = apart or printed_gap(emitter, before, scan);
    if (!spaced) return false;
    if (emit.is_dot(emitter, scan)) return false;
    if (emit.is_dot(emitter, before)) return false;
    return !welded;
}

fn printed_gap(emitter: *const Emitter, before: u32, scan: u32) bool {
    assert(before < scan);
    assert(scan < emitter.count);

    if (comment.header_semi_gap(emitter, before, scan)) return true;
    if (!emitter.policy.printed_gaps) return false;

    const spaced_before = emit.roled(emitter, before, brace.role_spaced);
    const trailing = emit.roled(emitter, scan, brace.role_spaced);
    const roled = spaced_before or trailing;

    if (roled) {
        if (!spaced_before) return true;
        if (!trailing) return true;
        return emitter.tokens[before].end() < emitter.tokens[scan].offset;
    }

    return printed_gap_keyword(emitter, before, scan);
}

fn printed_gap_keyword(emitter: *const Emitter, before: u32, scan: u32) bool {
    assert(before < scan);
    assert(scan < emitter.count);

    const token = emitter.tokens[scan];
    const kind = token.kind;
    const pointed = token.is_punctuation(.colon) or token.is_punctuation(.comma);
    const punctuated = pointed or token.is_punctuation(.semicolon);

    if (walk.is_close(kind)) return false;
    if (kind == .block_end) return false;
    if (punctuated) return false;
    if (separating(emitter, before)) return true;
    if (emitter.tokens[before].kind != .keyword) return false;
    if (emit.operand_at(emitter, before)) return false;
    if (emitter.policy.keyword_gaps) return true;
    if (line.word_is(emitter, before, emitter.policy.gap_words)) return true;

    const bracketed = token.is_punctuation(.bracket_open) or token.is_punctuation(.paren_open);
    return !bracketed;
}

fn closes_after(emitter: *const Emitter, scan: u32, to: u32) bool {
    assert(scan < emitter.count);
    assert(scan < to);

    var ahead = scan + 1;

    while (ahead < to) : (ahead += 1) {
        if (ahead >= emitter.count) break;

        const token = emitter.tokens[ahead];
        if (token.length == 0) continue;
        if (token.kind == .newline) continue;
        return walk.is_close(token.kind) or token.kind == .block_end;
    }

    return true;
}

fn tight_pair(emitter: *const Emitter, before: u32, scan: u32) bool {
    assert(before < scan);
    assert(scan < emitter.count);

    const held = emitter.tokens[before];
    const token = emitter.tokens[scan];
    const closes = token.is_punctuation(.paren_close) or token.is_punctuation(.bracket_close);
    const opener = held.is_punctuation(.paren_open) or held.is_punctuation(.bracket_open);
    const opening = token.is_punctuation(.paren_open) or token.is_punctuation(.bracket_open);
    const worded = held.kind == .identifier or walk.is_close(held.kind);
    const callee = worded or text_is(emitter, before, "!");
    const called = opening and callee;

    return opener or closes or called;
}

pub fn callee_columns(emitter: *const Emitter, open: u32) u32 {
    assert(open < emitter.count);

    const head = callee_head(emitter, open);
    if (head == open) return 0;

    assert(head < open);

    return walk.columns(emitter.source, emitter.tokens[head].offset, emitter.tokens[open].offset);
}

fn callee_head(emitter: *const Emitter, open: u32) u32 {
    assert(open < emitter.count);

    var head = open;
    var scan = open;

    for (0..core.type_scan_max) |_| {
        const back = emit.back_of(emitter, scan) orelse break;

        assert(back < scan);

        if (angle_count(emitter, back, '>') != null) {
            const found = angled_head(emitter, back) orelse break;

            head = found;
            scan = found;

            continue;
        }

        if (!callee_word(emitter, back)) break;

        head = back;
        scan = back;
    }

    assert(head <= open);

    return head;
}

fn callee_word(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    const bytes = emitter.tokens[position].text(emitter.source);
    if (walk.text_is(bytes, "::")) return true;
    if (walk.text_is(bytes, "!")) return true;
    if (bytes.len == 0) return false;

    for (bytes) |byte| {
        const word = std.ascii.isAlphanumeric(byte) or byte == '_';
        if (!word) return false;
    }

    return true;
}

pub fn angle_count(emitter: *const Emitter, position: u32, angle: u8) ?u32 {
    assert(position < emitter.count);
    assert(angle == '<' or angle == '>');

    const bytes = emitter.tokens[position].text(emitter.source);
    if (bytes.len == 0) return null;

    for (bytes) |byte| {
        if (byte != angle) return null;
    }

    assert(bytes.len <= std.math.maxInt(u32));

    return @intCast(bytes.len);
}

fn angled_head(emitter: *const Emitter, close: u32) ?u32 {
    assert(close < emitter.count);

    var angles = angle_count(emitter, close, '>') orelse return null;
    var scan = close;

    for (0..core.type_scan_max) |_| {
        const held = emit.back_of(emitter, scan) orelse return null;

        assert(held < scan);

        if (angle_count(emitter, held, '>')) |found| {
            angles += found;
        } else if (angle_count(emitter, held, '<')) |found| {
            angles -|= found;

            if (angles == 0) return angled_head_front(emitter, held);
        } else {}

        scan = held;
    }

    return null;
}

fn angled_head_front(emitter: *const Emitter, held: u32) ?u32 {
    assert(held < emitter.count);
    assert(angle_count(emitter, held, '<') != null);

    const front = emit.back_of(emitter, held) orelse return held;
    if (text_is(emitter, front, "::")) return front;
    if (walk.ends_operand(emitter.tokens[front].kind)) return null;
    return held;
}

fn angled_over(emitter: *const Emitter, open: u32) ?u32 {
    assert(open < emitter.count);

    var angles = angle_count(emitter, open, '<') orelse return null;
    var scan = open;

    for (0..core.type_scan_max) |_| {
        scan = emit.ahead_of(emitter, scan) orelse return null;

        assert(scan > open);

        if (angle_count(emitter, scan, '<')) |found| {
            angles += found;
        } else if (angle_count(emitter, scan, '>')) |found| {
            angles -|= found;

            if (angles == 0) return emit.ahead_of(emitter, scan);
        } else {}
    }

    return null;
}

fn chained_sole(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    if (!emitter.policy.chain_soles) return false;
    if (callee_columns(emitter, open) < emitter.options.indent_width) return false;

    const lead = operand_of(emitter, open) orelse return false;
    const tail = emit.back_of(emitter, close) orelse return false;
    var depth: u32 = 0;
    var scan = open + 1;

    while (scan < close) : (scan += 1) {
        const kind = emitter.tokens[scan].kind;
        const opens = walk.is_open(kind) or kind == .block_start;
        const closes = walk.is_close(kind) or kind == .block_end;

        if (opens) {
            depth += 1;
        } else if (closes) {
            depth -|= 1;
        } else if (depth == 0) {
            if (dotted(emitter, scan)) return chained_sole_link(emitter, scan, lead, tail);
        } else {}
    }

    return false;
}

fn chained_sole_link(emitter: *const Emitter, position: u32, lead: u32, tail: u32) bool {
    assert(position < emitter.count);
    assert(tail < emitter.count);

    const head = chain_head(emitter, position);
    const end, const links, _ = chain_end(emitter, head);

    if (head != lead) return false;
    if (end != tail) return false;
    return links >= 1;
}

fn chained_soled(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.policy.chain_soles);

    const lead = operand_of(emitter, open) orelse return false;

    _, const links, _ = chain_end(emitter, chain_head(emitter, lead));

    return links < 2;
}

fn chained_lined(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    const lead = emit.ahead_of(emitter, open) orelse return false;
    const tail = emit.back_of(emitter, close) orelse return false;

    if (callee_pathed(emitter, open) < emitter.options.indent_width) return false;
    if (chained_tailed(emitter, open, close)) return false;

    const flat = flat_columns(emitter, lead, tail + 1);
    return chained_at(emitter, lead) + flat > emitter.options.line_width;
}

fn callee_pathed(emitter: *const Emitter, open: u32) u32 {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var head = open;
    var scan = open;

    for (0..core.type_scan_max) |_| {
        const back = emit.back_of(emitter, scan) orelse break;

        assert(back < scan);

        if (text_is(emitter, back, "!")) {
            head = back;
            scan = back;

            continue;
        }

        if (!alphanumeric(emitter.tokens[back].text(emitter.source))) break;

        head = back;
        scan = back;

        const separator = emit.back_of(emitter, scan) orelse break;
        if (!text_is(emitter, separator, "::")) break;

        head = separator;
        scan = separator;
    }

    return walk.columns(emitter.source, emitter.tokens[head].offset, emitter.tokens[open].offset);
}

fn alphanumeric(bytes: []const u8) bool {
    assert(bytes.len <= std.math.maxInt(u32));

    if (bytes.len == 0) return false;

    for (bytes) |byte| {
        const word = std.ascii.isAlphanumeric(byte) or byte == '_';
        if (!word) return false;
    }

    return true;
}

fn chained_tailed(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    const tail = emit.back_of(emitter, close) orelse return false;
    var depth: u32 = 0;
    var scan = close;

    while (scan > open) {
        scan -= 1;

        const kind = emitter.tokens[scan].kind;
        const closes = walk.is_close(kind) or kind == .block_end;
        const opens = walk.is_open(kind) or kind == .block_start;

        if (closes) {
            depth += 1;
        } else if (opens) {
            depth -|= 1;
        } else if (depth == 0) {
            if (dotted(emitter, scan)) {
                const from = emitter.tokens[scan].offset;
                const to = emitter.tokens[tail].end();

                return body.parted_by(emitter, from, to) > 0;
            }
        } else {}
    }

    return false;
}

fn chained_point(emitter: *const Emitter, open: u32, close: u32, ends: u32) u32 {
    assert(open < close);
    assert(ends < emitter.count);

    const lead = emit.ahead_of(emitter, open) orelse return ends;
    const tail = emit.back_of(emitter, close) orelse return ends;
    const flat = flat_columns(emitter, lead, tail + 1);
    const over = chained_at(emitter, lead) + flat > emitter.options.line_width;

    if (combined(emitter, open) < emitter.options.indent_width) {
        return @min(linked_first(emitter, lead, tail), ends);
    }

    return @min(hug_point(emitter, lead, tail, over), ends);
}

fn combined(emitter: *const Emitter, open: u32) u32 {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var head = open;

    for (0..core.type_scan_max) |_| {
        const back = emit.back_of(emitter, head) orelse break;
        const token = emitter.tokens[back];

        assert(back < head);

        if (token.end() != emitter.tokens[head].offset) break;

        const marked = text_is(emitter, back, "::") or text_is(emitter, back, "!");
        const worded = token.kind == .identifier or token.kind == .keyword;

        if (!marked) {
            if (!worded) break;
        }

        head = back;
    }

    if (head < open) return flat_columns(emitter, head, open);
    return 0;
}

pub fn macro_argued(emitter: *const Emitter) bool {
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.depth < 2) return false;

    var index = emitter.depth - 1;

    while (index > 0) {
        index -= 1;

        const frame = emitter.nest[index];

        const delimited = frame.kind.eql(.{ .punctuation = .paren_open }) or
            frame.kind.eql(.{ .punctuation = .bracket_open });

        if (frame.kind == .block_start) return false;
        if (!delimited) continue;

        const close = join.closing_of(emitter, frame.open) orelse continue;
        if (macroed(emitter, frame.open, close)) return true;
    }

    return false;
}

fn macroed(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < emitter.count);
    assert(close < emitter.count);

    if (core.memo_found(emitter, .macroed, open, close)) |answer| return answer == 1;

    const held = macroed_scanned(emitter, open, close);

    core.memo_store(emitter, .macroed, open, close, @intFromBool(held));

    return held;
}

fn macroed_scanned(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < emitter.count);
    assert(close < emitter.count);

    if (!emitter.policy.macro_spans) return false;

    const bang = emit.word_before(emitter, open) orelse return false;
    if (!emitter.tokens[bang].is_punctuation(.bang)) return false;

    const name = emit.word_before(emitter, bang) orelse return false;
    if (!macro_word(emitter, name, bang)) return false;
    return !streamed(emitter, open, close);
}

fn macro_word(emitter: *const Emitter, name: u32, bang: u32) bool {
    assert(name < bang);
    assert(bang < emitter.count);

    const kind = emitter.tokens[name].kind;
    if (kind == .identifier) return true;
    if (kind != .keyword) return false;
    return emitter.tokens[name].end() == emitter.tokens[bang].offset;
}

pub fn macro_tailed(emitter: *const Emitter, close: u32) bool {
    assert(close < emitter.count);

    if (!emitter.tokens[close].is_punctuation(.paren_close)) return false;

    const open = emit.opened(emitter, close) orelse return false;

    assert(open < close);

    return macroed(emitter, open, close);
}

pub fn named(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    if (emitter.tokens[position].kind != .identifier) return false;

    if (emit.word_before(emitter, position)) |held| {
        assert(held < position);

        if (emit.is_dot(emitter, held)) return true;
    }

    if (!line.group_word(emitter, position)) return true;
    return list.member_worded(emitter, position);
}

pub fn objected(emitter: *const Emitter, before: u32, held: Token) bool {
    assert(before < emitter.count);
    assert(held.end() <= emitter.source.len);

    if (held.is_punctuation(.colon)) {
        if (split.armed(emitter, before)) return false;
        if (emit.mark_of(emitter, before) & brace.mark_label != 0) return false;
    }

    const assigning = held.is_punctuation(.assign) or held.is_punctuation(.bracket_open);
    const pairing = held.is_punctuation(.colon) or held.is_punctuation(.comma);
    const opening = assigning or pairing or held.is_punctuation(.paren_open);
    const bytes = held.text(emitter.source);
    const asked = emitter.policy.ternary_colon and walk.text_is(bytes, "?");
    const holed = held.kind == .block_start and emit.roled(emitter, before, brace.role_jsx_hole);
    const spread = emitter.policy.chain_simples and walk.text_is(bytes, "...");

    if (held.is_keyword(.@"return")) return true;
    if (opening) return true;
    if (own.compound_assign(emitter, before)) return true;
    if (asked) return true;
    if (holed) return true;
    if (objected_worded(emitter, before)) return true;
    if (walk.text_is(bytes, "yield")) return true;
    if (walk.text_is(bytes, "await")) return true;
    if (spread) return true;
    if (line.group_word(emitter, before)) return true;

    if (walk.text_is(bytes, ">")) {
        if (wrap.cast_open(emitter, before) != null) return true;
    }

    return objected_typed(emitter, before, held);
}

fn objected_worded(emitter: *const Emitter, before: u32) bool {
    assert(before < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!line.word_is(emitter, before, emitter.policy.object_words)) return false;

    const prior = emit.back_of(emitter, before) orelse return true;
    return !emit.is_dot(emitter, prior);
}

fn objected_typed(emitter: *const Emitter, before: u32, held: Token) bool {
    assert(before < emitter.count);
    assert(held.end() <= emitter.source.len);

    const bytes = held.text(emitter.source);
    const extended = emitter.policy.type_words.len > 0 and walk.text_is(bytes, "extends");
    const patterned = emitter.policy.body_owns and word_among(bytes, binding_patterns);

    if (walk.text_is(bytes, "<")) return true;
    if (extended) return true;
    if (walk.text_is(bytes, "&")) return true;
    if (walk.text_is(bytes, "|")) return true;
    if (patterned) return true;

    if (emitter.policy.binary_parts) {
        if (call.logical_operator(emitter, before)) return true;
    }

    if (loop_valued(emitter, before, held)) return true;
    if (held.kind != .identifier) return false;

    const word = emit.word_before(emitter, before) orelse return false;
    return line.word_is(emitter, word, emitter.policy.value_words);
}

fn loop_valued(emitter: *const Emitter, before: u32, held: Token) bool {
    assert(before < emitter.count);
    assert(held.end() <= emitter.source.len);

    if (!emitter.policy.chain_simples) return false;

    const bytes = held.text(emitter.source);
    const looped = walk.text_is(bytes, "in") or walk.text_is(bytes, "of");
    if (!looped) return false;

    const open = emit.opened(emitter, before) orelse return false;
    return list.headed_loop(emitter, open);
}

fn sole_call(emitter: *const Emitter, open: u32) u32 {
    assert(open < emitter.count);

    var budget = emitter.policy.call_width;
    var held = open;

    for (0..brace.nest_depth_max) |_| {
        const inner = sole_inner(emitter, held) orelse
            return sole_bracketed(emitter, open, held, budget);

        const width = callee_columns(emitter, inner) + 2;

        assert(inner > held);

        if (!emitter.policy.call_budgets) {
            held = inner;

            continue;
        }

        if (width > budget) return held;

        budget -= width;
        held = inner;
    }

    return held;
}

fn sole_bracketed(emitter: *const Emitter, open: u32, held: u32, budget: u32) u32 {
    assert(open < emitter.count);
    assert(held < emitter.count);

    if (held == open) return held;

    const found = sole_bracket(emitter, held) orelse return held;
    const lead = emit.ahead_of(emitter, held) orelse return held;
    const close = join.closing_of(emitter, held) orelse return held;

    assert(found > held);

    if (flat_columns(emitter, lead, close) > budget) return found;
    return held;
}

fn sole_bracket(emitter: *const Emitter, open: u32) ?u32 {
    assert(open < emitter.count);

    const close = join.closing_of(emitter, open) orelse return null;
    var scan = emit.ahead_of(emitter, open) orelse return null;
    if (scan >= close) return null;

    for (0..core.type_scan_max) |_| {
        const token = emitter.tokens[scan];
        const bracketed = token.is_punctuation(.bracket_open) or token.is_punctuation(.paren_open);

        assert(scan > open);

        if (bracketed) {
            const inner_close = join.closing_of(emitter, scan);
            const matched = std.meta.eql(inner_close, emit.back_of(emitter, close));
            if (matched) return scan;
            return null;
        }

        if (!text_is(emitter, scan, "&")) return null;

        scan = emit.ahead_of(emitter, scan) orelse return null;
    }

    return null;
}

fn operand_of(emitter: *const Emitter, open: u32) ?u32 {
    assert(open < emitter.count);

    var scan = emit.ahead_of(emitter, open) orelse return null;

    for (0..unary_walk_max) |_| {
        assert(scan > open);

        if (!line.word_is(emitter, scan, operand_unaries)) return scan;

        scan = emit.ahead_of(emitter, scan) orelse return null;
    }

    return scan;
}

pub fn sole_inner(emitter: *const Emitter, open: u32) ?u32 {
    assert(open < emitter.count);

    const close = join.closing_of(emitter, open) orelse return null;
    const steps: u32 = if (emitter.policy.call_nests) core.type_scan_max else 1;
    var scan = operand_of(emitter, open) orelse return null;

    for (0..steps) |_| {
        const angled = angle_count(emitter, scan, '<') != null;
        const naming = angled or callee_word(emitter, scan);
        if (!naming) return null;

        if (angled) {
            scan = angled_over(emitter, scan) orelse return null;
        } else {
            scan = emit.ahead_of(emitter, scan) orelse return null;
        }

        assert(scan > open);

        const opened = emitter.tokens[scan].is_punctuation(.paren_open) or
            macro_bracketed(emitter, scan);

        if (opened) {
            const inner_close = join.closing_of(emitter, scan);
            const matched = std.meta.eql(inner_close, sole_tail(emitter, close));
            if (!matched) return null;
            if (opaque_invoked(emitter, scan, inner_close.?)) return null;
            return scan;
        }
    }

    return null;
}

fn sole_framed(emitter: *const Emitter, frame: *const core.Frame) bool {
    assert(frame.open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (frame.kind.eql(.{ .punctuation = .paren_open })) return true;
    return macro_bracketed(emitter, frame.open);
}

fn macro_bracketed(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.call_budgets) return false;
    if (!emitter.tokens[open].is_punctuation(.bracket_open)) return false;

    const bang = emit.back_of(emitter, open) orelse return false;

    assert(bang < open);

    return emitter.tokens[bang].is_punctuation(.bang);
}

fn sole_tail(emitter: *const Emitter, close: u32) ?u32 {
    assert(close < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var tail = emit.back_of(emitter, close) orelse return null;
    if (!emitter.policy.call_budgets) return tail;

    for (0..unary_walk_max) |_| {
        if (!text_is(emitter, tail, "?")) return tail;

        tail = emit.back_of(emitter, tail) orelse return null;
    }

    return tail;
}

pub fn chain_stated(emitter: *const Emitter, close: u32, stop: u32) bool {
    assert(close <= stop);
    assert(stop < emitter.count);

    if (emitter.policy.call_width == 0) return false;

    const next = emit.ahead_of(emitter, stop) orelse return false;
    if (!dotted(emitter, next)) return false;
    if (join.statement_end(emitter, next) == null) return false;

    const before = emit.back_of(emitter, emitter.line_first) orelse return true;
    const kind = emitter.tokens[before].kind;
    if (kind == .block_start) return true;
    if (kind == .block_end) return true;
    return emitter.tokens[before].is_punctuation(.semicolon);
}

pub fn assign_strung(emitter: *const Emitter, position: u32, end: u32) bool {
    assert(position < end);
    assert(end < emitter.count);

    const token = emitter.tokens[position];
    const text = token.text(emitter.source);
    const cooked = text.len > 0 and text[0] == '"';
    const raw = std.mem.startsWith(u8, text, "r\"") or std.mem.startsWith(u8, text, "r#");

    if (token.kind != .string) return false;

    if (!cooked) {
        if (!raw) return false;
    }

    if (emit.ahead_of(emitter, position) != end) return false;
    if (std.mem.findScalar(u8, text, '\n') != null) return false;

    const width = walk.columns(emitter.source, token.offset, token.end());
    const lowered = (emitter.printed + 1) * emitter.options.indent_width;

    return lowered + width + 1 > emitter.options.line_width;
}

pub fn tuple_open(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    if (emitter.policy.call_width == 0) return false;
    if (!emitter.tokens[open].is_punctuation(.paren_open)) return false;
    if (list.calling(emitter, open)) return false;

    const before = emit.back_of(emitter, open) orelse return true;
    if (emitter.tokens[before].is_punctuation(.bang)) return false;
    return !list.closes_angle(emitter.tokens[before].text(emitter.source));
}

pub fn tuple_commas(emitter: *const Emitter, open: u32, close: u32) u32 {
    assert(open < close);
    assert(close < emitter.count);

    var counted: u32 = 0;
    var scan = open;

    for (0..core.define_scan_max) |_| {
        const next = emit.ahead_of(emitter, scan) orelse return counted;
        const token = emitter.tokens[next];

        if (next >= close) return counted;

        if (token.is_punctuation(.comma)) {
            if (!closure.barred(emitter, next)) counted += 1;
        }

        scan = next;

        const opens = walk.is_open(token.kind) or token.kind == .block_start;
        if (opens) scan = emitter.brackets.close_of(next) orelse return counted;
    }

    return counted;
}

pub fn tupled(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < emitter.count);
    assert(close < emitter.count);

    if (emitter.policy.call_width == 0) return false;
    if (!emitter.tokens[open].is_punctuation(.paren_open)) return false;

    const word = emit.word_before(emitter, open);
    const ahead = emit.ahead_of(emitter, close);
    const banged = if (word) |held| emitter.tokens[held].is_punctuation(.bang) else false;
    const bound = if (ahead) |held| line.word_is(emitter, held, bound_words) else false;

    if (banged) return false;
    if (bound) return false;
    return element_count(emitter, open, close) > 1;
}

pub fn operand_brace(emitter: *const Emitter, close: u32) bool {
    assert(close < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    if (emitter.tokens[close].kind != .block_end) return false;

    const open = emitter.brackets.open_of(close) orelse return false;

    assert(open < close);

    return valued_brace(emitter, open);
}

pub fn valued_brace(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    if (core.memo_found(emitter, .valued_brace, open, 0)) |answer| return answer == 1;

    const held = valued_brace_scanned(emitter, open);

    core.memo_store(emitter, .valued_brace, open, 0, @intFromBool(held));

    return held;
}

fn valued_brace_scanned(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    const held = emit.back_of(emitter, open) orelse return false;
    const kind = emitter.tokens[held].kind;
    const naming = kind == .identifier or text_is(emitter, held, "Self");

    assert(held < open);

    if (!naming) return false;
    return !leads_a_block(emitter, open);
}

fn leads_a_block(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    if (core.memo_found(emitter, .leads_a_block, open, 0)) |answer| return answer == 1;

    const held = leads_a_block_scanned(emitter, open);

    core.memo_store(emitter, .leads_a_block, open, 0, @intFromBool(held));

    return held;
}

fn leads_a_block_scanned(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    var depth: u32 = 0;
    var scan = open;

    for (0..core.type_scan_max) |_| {
        const held = emit.back_of(emitter, scan) orelse return false;
        const kind = emitter.tokens[held].kind;
        const closes = walk.is_close(kind) or kind == .block_end;
        const opens = walk.is_open(kind) or kind == .block_start;
        const ended = depth == 0 and kind == .block_end;

        assert(held < scan);

        if (ended) {
            if (!joins_a_value(emitter, held)) return false;
        }

        if (closes) {
            depth += 1;
        } else if (opens) {
            if (depth == 0) return false;

            depth -= 1;
        } else if (depth == 0) {
            if (line.word_is(emitter, held, emitter.policy.block_leads)) return true;
            if (leads_a_block_stopped(emitter, held)) return false;
        } else {}

        scan = held;
    }

    return false;
}

fn leads_a_block_stopped(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.tokens[position].kind != .block_end);

    if (emitter.tokens[position].is_punctuation(.semicolon)) return true;
    if (line.word_is(emitter, position, emitter.policy.head_stops)) return true;
    return text_is(emitter, position, "=>");
}

pub fn joins_a_value(emitter: *const Emitter, close: u32) bool {
    assert(close < emitter.count);

    const held = emit.ahead_of(emitter, close) orelse return false;

    assert(held > close);

    if (text_is(emitter, held, "#")) return false;
    if (text_is(emitter, held, "@")) return false;
    if (emitter.tokens[held].kind == .punctuation) return true;
    if (text_is(emitter, held, "else")) return true;
    return text_is(emitter, held, "as");
}

pub fn linked_bracket(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    const held = emit.back_of(emitter, open) orelse return false;
    const dot = emit.back_of(emitter, held) orelse return false;

    assert(dot < held);

    return emit.is_dot(emitter, dot);
}

fn dotted(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    if (!emit.is_dot(emitter, position)) return false;
    return !emit.ranges(emitter, position);
}

fn operand_opens(emitter: *const Emitter, prior: ?u32) bool {
    assert(emitter.count <= emitter.tokens.len);
    if (prior) |held| assert(held < emitter.count);

    const held = prior orelse return true;

    assert(held < emitter.count);

    return !walk.ends_operand(emitter.tokens[held].kind);
}

fn text_is(emitter: *const Emitter, position: u32, word: []const u8) bool {
    assert(position < emitter.count);
    assert(word.len > 0);

    return walk.text_eql(emitter.tokens[position].text(emitter.source), word);
}

fn word_among(bytes: []const u8, words: []const []const u8) bool {
    assert(words.len > 0);
    assert(bytes.len <= std.math.maxInt(u32));

    for (words) |word| {
        if (walk.text_eql(bytes, word)) return true;
    }

    return false;
}

pub fn fields_judged(emitter: *const Emitter, range: FieldRange) bool {
    assert(range.first <= range.last);
    assert(emitter.policy.field_width > 0);

    var stack: [brace.nest_depth_max]FieldFrame = undefined;
    var height: u32 = 1;
    var steps: u64 = 0;

    stack[0] = .{ .depth = 0, .range = range, .returned = false, .scan = range.first };

    while (height > 0) : (steps += 1) {
        assert(steps <= @as(u64, emitter.count) * (brace.nest_depth_max + 1));

        const frame = &stack[height - 1];

        switch (fields_step(emitter, frame)) {
            .parted => return true,
            .scanned => {},
            .nested => |child| {
                assert(height < brace.nest_depth_max);

                stack[height] = .{
                    .depth = 0,
                    .range = child,
                    .returned = false,
                    .scan = child.first,
                };

                height += 1;
            },
            .whole => {
                if (fields_measured(emitter, frame.range)) return true;

                height -= 1;

                if (height > 0) stack[height - 1].returned = true;
            },
        }
    }

    return false;
}

const FieldStep = union(enum) {
    nested: FieldRange,
    parted,
    scanned,
    whole,
};

fn fields_step(emitter: *const Emitter, frame: *FieldFrame) FieldStep {
    assert(frame.scan >= frame.range.first);
    assert(frame.scan <= frame.range.last);

    const scan = frame.scan;
    const kind = emitter.tokens[scan].kind;
    if (kind == .comment) return .parted;

    if (kind == .block_start) {
        if (!frame.returned) {
            if (split.fields_head(emitter, scan)) |child| return .{ .nested = child };
        }

        frame.returned = false;
    }

    const opens = walk.is_open(kind) or kind == .block_start;
    const closes = walk.is_close(kind) or kind == .block_end;

    if (opens) {
        frame.depth += 1;
    } else if (closes) {
        frame.depth -|= 1;
    } else if (frame.depth == 0) {
        if (scan != frame.range.last) {
            if (kind.eql(.{ .punctuation = .semicolon })) return .parted;
        }
    } else {}

    if (scan == frame.range.last) return .whole;

    const held = emit.ahead_of(emitter, scan) orelse return .whole;

    assert(held > scan);

    frame.scan = held;

    return .scanned;
}

fn fields_measured(emitter: *const Emitter, range: FieldRange) bool {
    assert(range.first <= range.last);
    assert(emitter.policy.field_width > 0);

    if (fields_called(emitter, range.first, range.last)) return false;
    return fields_width(emitter, range.first, range.last) > emitter.policy.field_width;
}

fn fields_called(emitter: *const Emitter, first: u32, last: u32) bool {
    assert(first <= last);
    assert(last < emitter.count);

    var scan = first;

    for (0..core.type_scan_max) |_| {
        if (emitter.tokens[scan].is_punctuation(.paren_open)) return true;
        if (scan == last) return false;

        const held = emit.ahead_of(emitter, scan) orelse return false;

        assert(held > scan);

        if (held > last) return false;

        scan = held;
    }

    return false;
}

fn fields_span(emitter: *const Emitter, from: u32, last: u32) u32 {
    assert(from <= last);
    assert(last < emitter.count);

    var found: u32 = 0;
    var scan = from;

    for (0..core.type_scan_max) |_| {
        found += emitter.tokens[scan].length;

        if (scan == last) break;

        const held = emit.ahead_of(emitter, scan) orelse break;

        assert(held > scan);

        if (held > last) break;

        found += @intFromBool(fields_spaced(emitter, scan, held));
        scan = held;
    }

    return found;
}

fn fields_spaced(emitter: *const Emitter, before: u32, after: u32) bool {
    assert(before < after);
    assert(after < emitter.count);

    const left = emitter.tokens[before];
    const right = emitter.tokens[after];
    if (right.offset > left.end()) return true;
    if (left.is_punctuation(.comma)) return true;
    if (left.is_punctuation(.semicolon)) return true;
    if (walk.text_is(left.text(emitter.source), "|")) return true;
    if (walk.text_is(right.text(emitter.source), "|")) return true;

    const left_worded = left.kind == .identifier or left.kind == .keyword;
    const right_worded = right.kind == .identifier or right.kind == .keyword;

    if (left_worded) {
        if (right_worded) return true;
    }

    if (left.kind == .block_start) {
        if (right.kind != .block_end) return true;
    }

    if (right.kind == .block_end) return left.kind != .block_start;
    return false;
}

fn fields_width(emitter: *const Emitter, first: u32, last: u32) u32 {
    assert(first <= last);
    assert(last < emitter.count);

    const whole = fields_span(emitter, first, last);
    var scan = first;

    for (0..core.type_scan_max) |_| {
        if (emitter.tokens[scan].kind != .identifier) return whole;

        const ahead = emit.ahead_of(emitter, scan) orelse return whole;
        if (ahead > last) return whole;

        const token = emitter.tokens[ahead];

        if (token.offset > emitter.tokens[scan].end()) {
            if (walk.text_is(token.text(emitter.source), "|")) return whole;
            const returned = 1 + fields_span(emitter, ahead, last);

            assert(returned < std.math.maxInt(u32));

            return returned;
        }

        if (token.is_punctuation(.paren_open)) {
            const returned = 5 + fields_span(emitter, ahead, last);

            assert(returned < std.math.maxInt(u32));

            return returned;
        }

        if (!token.is_punctuation(.comma)) return whole;

        const held = emit.ahead_of(emitter, ahead) orelse return whole;
        if (held > last) return whole;

        scan = held;
    }

    return whole;
}

pub fn chain_end(emitter: *const Emitter, head: u32) struct { u32, u32, u32 } {
    assert(head < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var angles: u32 = 0;
    var depth: u32 = 0;
    var end = head;
    var links: u32 = 0;
    var opened: Token.Kind = .newline;
    var parent = head;
    var scan = head;

    while (scan < emitter.count) : (scan += 1) {
        const kind = emitter.tokens[scan].kind;
        const opens = walk.is_open(kind) or kind == .block_start;
        const closes = walk.is_close(kind) or kind == .block_end;
        const leading_scan = depth == 0 and scan > head;

        if (leading_scan) {
            if (chain_end_body(emitter, head, scan)) break;
        }

        if (opens) {
            if (depth == 0) opened = kind;

            depth += 1;
        } else if (closes) {
            if (depth == 0) break;

            depth -= 1;

            const indexed = opened.eql(.{ .punctuation = .bracket_open }) and angles == 0;
            const reset = depth == 0 and indexed;

            if (reset) {
                links = 0;
                parent = scan;
            }
        } else if (depth == 0) {
            if (!chained_by(emitter, scan, &angles)) break;
        } else {}

        const linked = depth == 0 and angles == 0 and scan > head and dotted(emitter, scan);

        if (linked) links += 1;

        end = scan;
    }

    assert(end >= head);
    assert(parent >= head);

    return .{ end, links, parent };
}

fn chain_end_body(emitter: *const Emitter, head: u32, scan: u32) bool {
    assert(head < scan);
    assert(scan < emitter.count);

    if (emitter.tokens[scan].kind != .block_start) return false;
    if (initialised(emitter, scan)) return false;

    const held = emit.back_of(emitter, scan) orelse return true;
    if (held < head) return true;
    return !block_worded(emitter, held, scan);
}

fn chained_by(emitter: *const Emitter, position: u32, angles: *u32) bool {
    assert(position < emitter.count);
    assert(angles.* <= emitter.source.len);

    if (emit.ahead_of(emitter, position)) |held| {
        if (block_worded(emitter, position, held)) return true;
    }

    if (angles.* > 0) {
        if (angle_count(emitter, position, '>')) |found| {
            angles.* -|= found;

            return true;
        }

        if (angle_count(emitter, position, '<')) |found| {
            angles.* += found;

            return true;
        }
    }

    if (text_is(emitter, position, "<")) {
        if (chained_by_qualified(emitter, position, angles.*)) {
            angles.* += 1;

            return true;
        }
    }

    if (angles.* > 0) return true;
    return receives(emitter, position);
}

fn chained_by_qualified(emitter: *const Emitter, position: u32, angles: u32) bool {
    assert(position < emitter.count);
    assert(text_is(emitter, position, "<"));
    assert(angles < std.math.maxInt(u32));

    const held = emit.back_of(emitter, position) orelse return angles == 0;

    if (angles == 0) {
        if (!walk.ends_operand(emitter.tokens[held].kind)) return true;
    }

    return text_is(emitter, held, "::");
}

pub fn chain_head(emitter: *const Emitter, position: u32) u32 {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var depth: u32 = 0;
    var scan = position;

    for (0..core.head_scan_max) |_| {
        const held = emit.back_of(emitter, scan) orelse return scan;
        const kind = emitter.tokens[held].kind;
        const closes = walk.is_close(kind) or kind == .block_end;
        const opens = walk.is_open(kind) or kind == .block_start;

        assert(held < scan);

        if (chain_head_hole(emitter, held)) |open| {
            scan = open;

            continue;
        }

        if (closes) {
            if (depth == 0) {
                if (chain_head_parted(emitter, held, scan)) return scan;
                if (edge.header_closed(emitter, held, scan)) return scan;
            }

            depth += 1;
        } else if (opens) {
            if (depth == 0) return scan;

            depth -= 1;
        } else if (depth == 0) {
            if (!received(emitter, held, scan)) {
                if (!block_worded(emitter, held, scan)) {
                    scan = angled_head(emitter, held) orelse return scan;

                    continue;
                }
            }
        } else {}

        scan = held;
    }

    return scan;
}

fn chain_head_hole(emitter: *const Emitter, held: u32) ?u32 {
    assert(held < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (emitter.tokens[held].kind != .block_end) return null;

    const open = emitter.brackets.open_of(held) orelse return null;

    assert(open < held);

    if (!bind.spans_open(emitter, open)) return null;
    return open;
}

fn chain_head_parted(emitter: *const Emitter, held: u32, scan: u32) bool {
    assert(held < scan);
    assert(scan < emitter.count);

    const ended = emitter.tokens[held].kind == .block_end or !emit.is_dot(emitter, scan);
    if (!ended) return false;
    if (!emitter.policy.head_blocks) return false;
    return body.parts_at(emitter, held, scan);
}

fn received(emitter: *const Emitter, held: u32, scan: u32) bool {
    assert(held < scan);
    assert(scan < emitter.count);

    if (walk.substituting(emitter.source, emitter.tokens[held])) return false;
    if (text_is(emitter, held, "!")) return walk.is_open(emitter.tokens[scan].kind);
    return receives(emitter, held);
}

fn receives(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const kind = emitter.tokens[position].kind;
    if (kind == .keyword) return line.word_is(emitter, position, receive_words);
    if (kind == .identifier) return true;
    if (kind == .number) return true;
    if (kind == .string) return true;

    if (emitter.policy.header_levels) {
        if (line.word_is(emitter, position, unwrap_marks)) return true;
    }

    return line.word_is(emitter, position, receive_marks);
}

fn block_worded(emitter: *const Emitter, held: u32, scan: u32) bool {
    assert(held < emitter.count);
    assert(scan < emitter.count);

    if (!line.word_is(emitter, held, block_words)) return false;
    if (emitter.tokens[scan].kind == .block_start) return true;
    return line.word_is(emitter, scan, block_words);
}

pub fn chain_tried(emitter: *const Emitter, head: u32, stop: u32) u32 {
    assert(head <= stop);
    assert(stop < emitter.count);

    const last, const links, _ = chain_end(emitter, head);

    if (links == 0) return 0;
    if (last != stop) return 0;
    const returned = 2 * chain_tries(emitter, head, last);

    assert(returned < std.math.maxInt(u32));

    return returned;
}

pub fn chain_tries(emitter: *const Emitter, head: u32, end: u32) u32 {
    assert(head < emitter.count);
    assert(end < emitter.count);

    var tries: u32 = 0;
    var scan = end;

    while (scan > head) {
        const bytes = emitter.tokens[scan].text(emitter.source);
        if (!questioned(bytes)) break;

        tries += @intCast(bytes.len);

        const found = emit.back_of(emitter, scan) orelse break;

        assert(found < scan);

        scan = found;
    }

    return tries;
}

fn questioned(bytes: []const u8) bool {
    assert(bytes.len <= std.math.maxInt(u32));

    if (bytes.len == 0) return false;

    for (bytes) |byte| {
        if (byte != '?') return false;
    }

    return true;
}

fn chain_margin(emitter: *const Emitter, end: u32) u32 {
    assert(end < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const held = emit.ahead_of(emitter, end) orelse return 0;
    return @intFromBool(separating(emitter, held));
}

fn chained_indent(emitter: *const Emitter, head: u32) u32 {
    assert(head < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const source_indent = indent_of(emitter, head);

    if (statement_word(emitter, head)) |held| {
        if (held < head) return indent_of(emitter, held);
    }

    const curly = emit.back_of(emitter, head) orelse return source_indent;
    if (emitter.tokens[curly].kind != .block_start) return source_indent;

    const lead = statement_word(emitter, curly) orelse return source_indent;
    if (lead >= curly) return source_indent;
    return indent_of(emitter, lead);
}

fn assign_seated(emitter: *const Emitter, head: u32) bool {
    assert(head < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (heads_line(emitter, head)) return false;

    const lead = statement_word(emitter, head) orelse return false;
    if (lead >= head) return false;
    if (assigned_value(emitter, lead, head) != head) return false;

    const end, _, _ = chain_end(emitter, head);
    const stop = statement_close(emitter, end);
    const under = indent_of(emitter, lead);
    if (under + flat_columns(emitter, lead, stop + 1) <= emitter.options.line_width) return false;

    const seated = under + emitter.options.indent_width + flat_columns(emitter, head, stop + 1);
    return seated <= emitter.options.line_width;
}

fn rooting(emitter: *const Emitter, head: u32, position: u32) Rooting {
    assert(head < position);
    assert(position < emitter.count);

    if (emit.ahead_of(emitter, head) != position) return .{ .verdict = false };

    const back = emit.back_of(emitter, head) orelse return .{ .verdict = false };
    if (emitter.tokens[back].kind == .block_start) return .{ .back = back };

    const width = emitter.tokens[head].length;

    const offset = root_offset(emitter, head) orelse
        line.column_of(emitter, head) - leading(emitter, head);

    return .{ .verdict = width <= emitter.options.indent_width -| offset };
}

fn rooted_block(emitter: *const Emitter, head: u32) bool {
    assert(head < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const token = emitter.tokens[head];

    return walk.columns(emitter.source, token.offset, token.end()) <=
        emitter.options.indent_width;
}

fn root_offset(emitter: *const Emitter, head: u32) ?u32 {
    assert(head < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const lead = statement_word(emitter, head) orelse return null;
    if (lead >= head) return null;

    if (assigned_value(emitter, lead, head) != head) {
        if (!condition_valued(emitter, lead, head)) return null;
        const returned = flat_columns(emitter, lead, head) + 1;

        assert(returned < std.math.maxInt(u32));

        return returned;
    }

    if (assign_seated(emitter, head)) return 0;
    const returned = flat_columns(emitter, lead, head) + 1;

    assert(returned < std.math.maxInt(u32));

    return returned;
}

pub fn branch_stop(emitter: *const Emitter, parted: ?u32, last: u32) ?u32 {
    assert(last < emitter.count);
    if (parted) |held| assert(held < emitter.count);

    const held = parted orelse return null;

    assert(held < emitter.count);

    return branch_extended(emitter, held, last) orelse held;
}

fn branch_extended(emitter: *const Emitter, open: u32, last: u32) ?u32 {
    assert(open < emitter.count);
    assert(last < emitter.count);

    if (join.arm_extends(emitter, open, last)) return open;
    if (emitter.tokens[open].kind != .block_start) return null;

    var close = emit.closing(emitter, open) orelse return null;

    for (0..join.define_scan_max) |_| {
        const word = emit.ahead_of(emitter, close) orelse return null;
        if (!walk.text_is(emitter.tokens[word].text(emitter.source), "else")) return null;

        const else_block = branch_block(emitter, word, last) orelse return null;
        if (join.arm_extends(emitter, else_block, last)) return else_block;

        close = emit.closing(emitter, else_block) orelse return null;
    }

    return null;
}

fn branch_block(emitter: *const Emitter, word: u32, last: u32) ?u32 {
    assert(word < last);
    assert(last < emitter.count);

    var depth: u32 = 0;
    var scan = word;

    for (0..join.define_scan_max) |_| {
        scan = emit.ahead_of(emitter, scan) orelse return null;

        if (scan >= last) return null;

        const kind = emitter.tokens[scan].kind;

        if (depth == 0) {
            if (kind == .block_start) return scan;
        }

        if (walk.is_open(kind)) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            depth -|= 1;
        } else {}
    }

    return null;
}

fn condition_valued(emitter: *const Emitter, lead: u32, head: u32) bool {
    assert(lead < head);
    assert(head < emitter.count);

    const assign = emit.back_of(emitter, head) orelse return false;
    if (assign <= lead) return false;
    if (!text_is(emitter, assign, "=")) return false;

    var depth: u32 = 0;
    var scan = lead + 1;

    while (scan < assign) : (scan += 1) {
        const kind = emitter.tokens[scan].kind;

        if (walk.is_open(kind)) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            depth -|= 1;
        } else if (depth == 0) {
            if (text_is(emitter, scan, "let")) return true;
        } else {}
    }

    return false;
}

fn rooted_parted(emitter: *const Emitter, head: u32, position: u32) bool {
    assert(head < position);
    assert(position < emitter.count);

    if (emitter.policy.call_width == 0) return false;

    if (emitter.policy.call_budgets) {
        if (strung_spans(emitter, head, position)) return true;
    }

    const close = emit.back_of(emitter, position) orelse return false;
    const token = emitter.tokens[close];
    const bracketed = token.is_punctuation(.paren_close) or token.is_punctuation(.bracket_close);
    if (!bracketed) return false;

    const open = emitter.brackets.open_of(close) orelse return false;
    if (open < head) return false;
    if (emit.ahead_of(emitter, open) == close) return false;
    if (listed_count(emitter, open, close) <= 1) return false;
    return flat_columns(emitter, open + 1, close) > emitter.policy.call_width;
}

fn linked_over(emitter: *const Emitter, head: u32, end: u32) bool {
    assert(head < emitter.count);
    assert(end < emitter.count);

    var depth: u32 = 0;
    var scan = head + 1;

    while (scan <= end) : (scan += 1) {
        const kind = emitter.tokens[scan].kind;
        const opens = walk.is_open(kind) or kind == .block_start;
        const closes = walk.is_close(kind) or kind == .block_end;

        if (opens) {
            depth += 1;
        } else if (closes) {
            depth -|= 1;
        } else if (depth == 0) {
            if (linked_over_parted(emitter, scan)) return true;
        } else {}
    }

    return false;
}

fn linked_over_parted(emitter: *const Emitter, scan: u32) bool {
    assert(scan < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emit.is_dot(emitter, scan)) return false;

    const held = emit.back_of(emitter, scan) orelse return false;
    return body.parts_at(emitter, held, scan);
}

fn linked_first(emitter: *const Emitter, head: u32, end: u32) u32 {
    assert(head <= end);
    assert(end < emitter.count);

    var depth: u32 = 0;
    var scan = head;

    while (scan <= end) : (scan += 1) {
        const kind = emitter.tokens[scan].kind;
        const opens = walk.is_open(kind) or kind == .block_start;
        const closes = walk.is_close(kind) or kind == .block_end;

        if (opens) {
            depth += 1;
        } else if (closes) {
            depth -|= 1;
        } else if (depth == 0) {
            const linked = scan > head and dotted(emitter, scan);
            if (linked) return scan;
        } else {}
    }

    assert(end + 1 <= emitter.count);

    return end + 1;
}

fn flat_line(emitter: *const Emitter, from: u32, to: u32) bool {
    assert(from < emitter.count);
    assert(emitter.count == emitter.tokens.len);
    assert(to <= emitter.count);

    var scan = from;

    while (scan < to) : (scan += 1) {
        if (scan >= emitter.count) break;

        const bytes = emitter.tokens[scan].text(emitter.source);
        if (std.mem.findScalar(u8, bytes, '\n') != null) return false;
    }

    return true;
}

fn linked_braced(emitter: *const Emitter, from: u32, to: u32) bool {
    assert(from < emitter.count);
    assert(emitter.count == emitter.tokens.len);
    assert(to <= emitter.count);

    var scan = from;

    while (scan <= to) : (scan += 1) {
        if (scan >= emitter.count) break;
        if (emitter.tokens[scan].kind == .block_start) return true;
    }

    return false;
}

fn hug_point(emitter: *const Emitter, head: u32, end: u32, overflowing: bool) u32 {
    assert(head <= end);
    assert(end < emitter.count);

    const past = end + 1;
    const link = hug_link(emitter, head, end);

    assert(past <= emitter.count);

    const open = opened_after(emitter, link, end) orelse return past;
    const close = join.closing_of(emitter, open) orelse return past;
    const inner = flat_columns(emitter, open + 1, close);
    const breaks = overflowing or inner > emitter.policy.call_width;

    if (capped_list(emitter, open, close)) {
        if (breaks) {
            const tailed = lambda_tailed(emitter, open, close) or sole_lambda_tailed(emitter, open);

            if (!tailed) {
                assert(open + 1 <= emitter.count);

                return open + 1;
            }
        }
    }

    const curly = braced_after(emitter, open, close) orelse return past;
    const reached = chained_at(emitter, head) + flat_columns(emitter, head, curly + 1);

    if (reached > emitter.options.line_width) {
        assert(open + 1 <= emitter.count);

        return open + 1;
    }

    if (overflowing) {
        assert(curly + 1 < std.math.maxInt(u32));

        return curly + 1;
    }

    if (blocked_over(emitter, curly)) {
        assert(curly + 1 < std.math.maxInt(u32));

        return curly + 1;
    }

    assert(end + 1 <= emitter.count);

    return end + 1;
}

fn hug_link(emitter: *const Emitter, head: u32, end: u32) u32 {
    assert(head <= end);
    assert(end < emitter.count);

    var depth: u32 = 0;
    var link = head;
    var scan = head;

    while (scan <= end) : (scan += 1) {
        const kind = emitter.tokens[scan].kind;
        const opens = walk.is_open(kind) or kind == .block_start;
        const closes = walk.is_close(kind) or kind == .block_end;

        if (opens) {
            depth += 1;
        } else if (closes) {
            depth -|= 1;
        } else if (depth == 0) {
            if (dotted(emitter, scan)) link = scan;
        } else {}
    }

    assert(link >= head);

    return link;
}

fn opened_after(emitter: *const Emitter, link: u32, end: u32) ?u32 {
    assert(link <= end);
    assert(end < emitter.count);

    var scan = link;

    while (scan <= end) : (scan += 1) {
        if (walk.is_open(emitter.tokens[scan].kind)) return scan;
    }

    return null;
}

fn braced_after(emitter: *const Emitter, open: u32, close: u32) ?u32 {
    assert(open < close);
    assert(close < emitter.count);

    var scan = open + 1;

    while (scan < close) : (scan += 1) {
        if (emitter.tokens[scan].kind == .block_start) {
            assert(scan <= emitter.count);

            return scan;
        }
    }

    return null;
}

fn lambda_tailed(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    const curly = braced_after(emitter, open, close) orelse return false;
    const end = join.closing_of(emitter, curly) orelse return false;
    const tail = emit.back_of(emitter, close) orelse return false;
    if (tail <= open) return false;

    const comma_tail = commas(emitter, tail) and emit.back_of(emitter, tail) == end;
    const tailed = tail == end or comma_tail;
    if (!tailed) return false;

    const bar = emit.back_of(emitter, curly) orelse return false;
    return line.word_is(emitter, bar, lambda_heads);
}

fn sole_lambda_tailed(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.call_budgets) return false;

    const inner = sole_call(emitter, open);
    if (inner == open) return false;

    const close = join.closing_of(emitter, inner) orelse return false;
    return lambda_tailed(emitter, inner, close);
}

fn capped_list(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    var barred = false;
    var depth: u32 = 0;
    var scan = open + 1;

    while (scan < close) : (scan += 1) {
        const kind = emitter.tokens[scan].kind;
        const opens = walk.is_open(kind) or kind == .block_start;
        const closes = walk.is_close(kind) or kind == .block_end;

        if (opens) {
            depth += 1;
        } else if (closes) {
            depth -|= 1;
        } else if (depth == 0) {
            if (text_is(emitter, scan, "|")) {
                barred = !barred;
            } else if (barred) {} else {
                if (commas(emitter, scan)) return true;
            }
        } else {}
    }

    return !line.word_is(emitter, open + 1, lambda_leads);
}

fn literal_head(emitter: *const Emitter, curly: u32) bool {
    assert(curly < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const held = emit.back_of(emitter, curly) orelse return false;
    if (emitter.tokens[held].kind == .identifier) return true;
    return text_is(emitter, held, ">");
}

fn blocked_over(emitter: *const Emitter, curly: u32) bool {
    assert(curly < emitter.count);
    assert(emitter.tokens[curly].kind == .block_start);

    const close = join.closing_of(emitter, curly) orelse return true;

    if (emitter.policy.literal_width > 0) {
        if (literal_head(emitter, curly)) {
            const flat = flat_columns(emitter, curly + 1, close);
            if (flat > emitter.policy.literal_width) return true;
        }
    }

    if (emit.ahead_of(emitter, curly)) |held| {
        if (line.word_is(emitter, held, branch_last_words)) return true;
    }

    if (macro_stated(emitter, curly, close)) return true;
    if (macro_lined(emitter, curly, close)) return true;

    var depth: u32 = 0;
    var scan = curly + 1;

    while (scan < close) : (scan += 1) {
        const token = emitter.tokens[scan];
        const opens = walk.is_open(token.kind) or token.kind == .block_start;
        const closes = walk.is_close(token.kind) or token.kind == .block_end;

        if (opens) {
            depth += 1;
        } else if (closes) {
            depth -|= 1;
        } else if (depth == 0) {
            if (token.kind == .comment) return true;
            if (token.is_punctuation(.semicolon)) return true;
        } else {}
    }

    return false;
}

fn macro_lined(emitter: *const Emitter, curly: u32, close: u32) bool {
    assert(curly < close);
    assert(close < emitter.count);

    if (!emitter.policy.call_budgets) return false;
    if (macro_name(emitter, curly) == null) return false;
    return body.parted_by(emitter, emitter.tokens[curly].end(), emitter.tokens[close].offset) > 0;
}

fn macro_stated(emitter: *const Emitter, curly: u32, close: u32) bool {
    assert(curly < close);
    assert(close < emitter.count);

    if (emitter.policy.call_width == 0) return false;

    var scan = emit.ahead_of(emitter, curly) orelse return false;

    for (0..core.define_scan_max) |_| {
        const kind = emitter.tokens[scan].kind;

        if (kind != .identifier) {
            if (kind != .keyword) return false;
        }

        const next = emit.ahead_of(emitter, scan) orelse return false;

        if (text_is(emitter, next, "::")) {
            scan = emit.ahead_of(emitter, next) orelse return false;

            continue;
        }

        if (!emitter.tokens[next].is_punctuation(.bang)) return false;

        const open = emit.ahead_of(emitter, next) orelse return false;
        if (emitter.tokens[open].kind != .block_start) return false;

        const shut = join.closing_of(emitter, open) orelse return false;
        return emit.ahead_of(emitter, shut) == close;
    }

    return false;
}

fn defined_wide(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    if (!emitter.policy.define_widths) return false;
    if (!emitter.tokens[open].is_punctuation(.paren_open)) return false;

    const ahead = emit.ahead_of(emitter, close) orelse return false;

    if (emitter.tokens[ahead].kind != .block_start) {
        if (!line.word_is(emitter, ahead, define_ends)) return false;
    }

    const held = emit.back_of(emitter, open) orelse return false;
    const angled = angle_count(emitter, held, '>') != null;
    const naming = emitter.tokens[held].kind == .identifier or angled;
    if (!naming) return false;

    const head = statement_word(emitter, open) orelse return false;
    if (head >= open) return false;

    const end = defined_end(emitter, close);
    const from = emitter.tokens[head].offset;
    const to = emitter.tokens[end].end();
    if (body.parted_by(emitter, from, to) > 0) return false;

    const under = emitter.printed * emitter.options.indent_width;
    return under + flat_columns(emitter, head, end + 1) > emitter.options.line_width;
}

fn defined_end(emitter: *const Emitter, close: u32) u32 {
    assert(close < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var depth: u32 = 0;
    var scan = close;

    for (0..core.type_scan_max) |_| {
        const held = emit.ahead_of(emitter, scan) orelse return scan;
        const kind = emitter.tokens[held].kind;
        const semi = kind.eql(.{ .punctuation = .semicolon });
        const ended = kind == .block_start or semi or text_is(emitter, held, "where");

        assert(held > scan);

        if (depth == 0) {
            if (ended) return held;
        }

        if (walk.is_open(kind)) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            depth -|= 1;
        } else {}

        scan = held;
    }

    return close;
}

pub fn defined_stream(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    var lambda = false;
    var prior: ?u32 = null;
    var scan = open + 1;

    while (scan < close) : (scan += 1) {
        const token = emitter.tokens[scan];
        const opens = operand_opens(emitter, prior);
        const barred = text_is(emitter, scan, "|") and (lambda or opens);

        if (barred) {
            lambda = !lambda;
        } else if (lambda) {} else {
            if (defined_juxtaposed(emitter, scan)) return true;
        }

        if (token.length > 0) prior = scan;
    }

    return false;
}

fn defined_juxtaposed(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!walk.ends_operand(emitter.tokens[position].kind)) return false;

    const held = emit.ahead_of(emitter, position) orelse return false;
    return text_is(emitter, held, "$");
}

pub fn unparsable(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    const parsed = emitter.tokens[open].kind != .block_start;
    var depth: u32 = 0;
    var lambda = false;
    var prior: ?u32 = null;
    var scan = open + 1;

    while (scan < close) : (scan += 1) {
        const token = emitter.tokens[scan];
        const kind = token.kind;
        const opens = operand_opens(emitter, prior);
        const barred = text_is(emitter, scan, "|") and (lambda or opens);
        const nests = walk.is_open(kind) or kind == .block_start;
        const unnests = walk.is_close(kind) or kind == .block_end;
        const level = !lambda and depth == 0;
        const looped = level and opens and text_is(emitter, scan, "in");
        const typed = level and parsed and text_is(emitter, scan, ":");
        const prefixed = level and parsed and prefix_misplaced(emitter, prior, scan);

        if (looped) return true;
        if (typed) return true;
        if (prefixed) return true;

        if (barred) {
            lambda = !lambda;
        } else if (nests) {
            depth += 1;
        } else if (unnests) {
            depth -|= 1;
        } else {}

        if (token.length > 0) prior = scan;
    }

    return false;
}

pub fn invoked(emitter: *const Emitter) bool {
    assert(emitter.depth <= brace.nest_depth_max);
    assert(emitter.count == emitter.tokens.len);

    var inside = false;

    for (emitter.nest[0..emitter.depth]) |*frame| {
        if (invoked_body(emitter, frame)) {
            inside = false;

            continue;
        }

        const name = macro_name(emitter, frame.open) orelse continue;
        const arrayed = frame.kind.eql(.{ .punctuation = .bracket_open });
        const vectored = text_is(emitter, name, "vec");

        inside = inside or !arrayed or !vectored;
    }

    return inside;
}

fn invoked_body(emitter: *const Emitter, frame: *const core.Frame) bool {
    assert(frame.open < emitter.count);
    assert(emitter.depth > 0);

    if (frame.kind != .block_start) return false;
    if (valued_brace(emitter, frame.open)) return false;
    return line.head_word(emitter, frame.open, macro_arms) == null;
}

fn macro_name(emitter: *const Emitter, open: u32) ?u32 {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const bang = emit.back_of(emitter, open) orelse return null;
    if (!text_is(emitter, bang, "!")) return null;

    const name = emit.back_of(emitter, bang) orelse return null;
    if (!macro_word(emitter, name, bang)) return null;
    return name;
}

pub fn hugged_over(emitter: *const Emitter, curly: u32, close: u32) bool {
    assert(curly < emitter.count);
    assert(close < emitter.count);

    if (emitter.policy.call_width == 0) return false;

    const ahead = emit.ahead_of(emitter, close) orelse return false;
    const end = if (commas(emitter, ahead)) emit.ahead_of(emitter, ahead) orelse ahead else ahead;
    const kind = emitter.tokens[end].kind;
    if (!walk.is_close(kind)) return false;
    if (kind == .block_end) return false;

    const open = emitter.brackets.open_of(end) orelse return false;
    if (open >= curly) return false;

    const head = hugged_head(emitter, curly, open) orelse return false;
    if (head <= open) return false;

    const stop = join.closing_of(emitter, open) orelse return false;
    const from = emitter.tokens[open].end();
    const spread = body.parted_by(emitter, from, emitter.tokens[curly].offset);
    if (spread > 0) return false;
    if (!elemental_list(emitter, open, stop)) return false;

    const offset = flat_columns(emitter, open + 1, head) + 1;
    const curly_columns = flat_columns(emitter, open + 1, curly + 1);
    if (curly_columns > join.lambda_room(emitter, open, curly)) return false;

    const width = flat_columns(emitter, head, close + 1);

    if (offset >= emitter.policy.call_width) return false;
    return width > emitter.policy.call_width - offset;
}

pub fn streamed(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < emitter.count);
    assert(close < emitter.count);

    if (core.memo_found(emitter, .streamed, open, close)) |answer| return answer == 1;

    const held = streamed_scanned(emitter, open, close);

    core.memo_store(emitter, .streamed, open, close, @intFromBool(held));

    return held;
}

fn streamed_scanned(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < emitter.count);
    assert(close < emitter.count);

    if (opaqued(emitter, open)) return true;
    if (interpolated(emitter, open, close)) return true;

    var stream: Stream = Stream.empty;
    var scan = open + 1;

    while (scan < close) : (scan += 1) {
        const token = emitter.tokens[scan];
        const opens = operand_opens(emitter, stream.prior);
        const barred = text_is(emitter, scan, "|") and (stream.lambda or opens);

        if (barred) {
            stream.lambda = !stream.lambda;
            stream.prior = scan;

            continue;
        }

        if (!stream.lambda) {
            if (streamed_stops(emitter, &stream, scan, opens)) return true;
        }

        stream.nest(emitter, scan);

        if (!stream.lambda) {
            if (streamed_joins(emitter, &stream, scan)) return true;
        }

        if (token.length > 0) stream.prior = scan;
    }

    return false;
}

pub fn arm_open_written(emitter: *const Emitter, close: u32) ?bool {
    assert(close < emitter.count);
    assert(emitter.tokens[close].kind == .block_end);

    const open = emit.opened(emitter, close) orelse return null;
    const arrow = emit.back_of(emitter, open) orelse return null;
    if (!text_is(emitter, arrow, "=>")) return null;
    if (emitter.closed.open == open) return true;

    for (emitter.nest[0..emitter.depth]) |frame| {
        if (frame.open == open) return true;
    }

    return false;
}

pub fn flat_glued(emitter: *const Emitter, next: u32, scan: u32) bool {
    assert(scan < next);
    assert(next < emitter.count);

    if (split.welded(emitter, next, scan)) return true;

    const depth = emitter.brackets.angles_at(next);
    const opened = depth > emitter.brackets.angles_at(scan) and join.angle_generic(emitter, scan);
    if (opened) return true;
    if (depth == 0) return false;
    if (!list.closes_angle(emitter.tokens[next].text(emitter.source))) return false;
    return join.angle_head(emitter, next) != null;
}

pub fn header_dropped(emitter: *const Emitter, next: u32) bool {
    assert(next < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    if (!join.flat_dropped(emitter, next)) return false;

    const close = emit.ahead_of(emitter, next) orelse return false;
    return !macro_tailed(emitter, close);
}

pub fn impl_angled(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    if (!text_is(emitter, open, "<")) return false;

    const word = emit.back_of(emitter, open) orelse return false;
    return emitter.tokens[word].kind == .keyword and text_is(emitter, word, "impl");
}

fn impl_parted(emitter: *const Emitter, position: u32, prior: u32) bool {
    assert(position < emitter.count);
    assert(prior < position);

    if (!text_is(emitter, prior, ">")) return false;

    const head = emitter.line_first;
    if (head >= prior) return false;
    if (emitter.tokens[head].kind != .keyword) return false;
    if (!text_is(emitter, head, "impl")) return false;

    const open = emit.ahead_of(emitter, head) orelse return false;
    if (!impl_angled(emitter, open)) return false;
    if (join.angle_close(emitter, open) != prior) return false;

    const end = impl_header_end(emitter, position) orelse return false;
    const after = emit.ahead_of(emitter, end) orelse return false;
    if (!text_is(emitter, after, "for")) return false;
    if (!impl_braced(emitter, after)) return false;

    const under = emitter.printed * emitter.options.indent_width;
    return under + flat_columns(emitter, head, end + 1) > emitter.options.line_width;
}

fn impl_braced(emitter: *const Emitter, word: u32) bool {
    assert(word < emitter.count);

    var scan = word;

    for (0..core.type_scan_max) |_| {
        const next = emit.ahead_of(emitter, scan) orelse return false;
        const token = emitter.tokens[next];
        if (token.kind == .block_start) return body.parts_at(emitter, scan, next);
        if (token.is_punctuation(.semicolon)) return false;

        scan = next;
    }

    return false;
}

fn impl_header_end(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);

    var scan = position;

    for (0..core.type_scan_max) |_| {
        const next = emit.ahead_of(emitter, scan) orelse return null;
        const token = emitter.tokens[next];
        if (token.kind == .block_start) return scan;
        if (token.is_punctuation(.semicolon)) return null;
        if (text_is(emitter, next, "where")) return scan;
        if (text_is(emitter, next, "for")) return scan;

        scan = next;
    }

    return null;
}

pub fn impl_width(emitter: *const Emitter, head: u32, close: u32) u32 {
    assert(head < close);
    assert(close < emitter.count);

    var prior: ?u32 = null;
    var width: u32 = 0;
    var scan = head;

    while (scan <= close) : (scan += 1) {
        const token = emitter.tokens[scan];
        if (token.length == 0) continue;
        if (token.kind == .newline) continue;

        const next = emit.ahead_of(emitter, scan) orelse close;
        const dropped = token.is_punctuation(.comma) and next == close;
        if (dropped) continue;

        if (prior) |before| {
            const apart = emitter.tokens[before].end() < token.offset;
            const lined = body.parts_at(emitter, before, scan);
            const opened = text_is(emitter, before, "<") and lined;
            const closed = scan == close and lined;

            width += @intFromBool(apart and !opened and !closed);
        }

        width += walk.columns(emitter.source, token.offset, token.end());
        prior = scan;
    }

    return width;
}

pub fn angle_reserved(emitter: *const Emitter, open: u32, stop: u32) u32 {
    assert(open < stop);
    assert(stop < emitter.count);

    if (!emitter.tokens[stop].is_punctuation(.paren_open)) return 0;

    const name = emit.back_of(emitter, open) orelse return 0;
    const keyword = emit.back_of(emitter, name) orelse return 0;
    if (emitter.tokens[keyword].kind != .keyword) return 0;
    if (!text_is(emitter, keyword, "fn")) return 0;

    const shut = join.closing_of(emitter, stop) orelse return 0;
    return if (fn_braced(emitter, shut)) fn_braced_reserve else fn_reserve;
}

fn fn_braced(emitter: *const Emitter, shut: u32) bool {
    assert(shut < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    var scan = shut;

    for (0..join.define_scan_max) |_| {
        scan = emit.ahead_of(emitter, scan) orelse return false;

        const kind = emitter.tokens[scan].kind;
        if (kind == .block_start) return true;
        if (kind.eql(.{ .punctuation = .semicolon })) return false;
        if (text_is(emitter, scan, "where")) return false;

        if (walk.is_open(kind)) {
            scan = join.closing_of(emitter, scan) orelse return false;
        }
    }

    return false;
}

pub fn sole_free(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    var scan = emit.ahead_of(emitter, open) orelse return false;

    for (0..unary_walk_max) |_| {
        if (scan >= close) return false;
        if (!line.word_is(emitter, scan, sole_prefixes)) break;

        scan = emit.ahead_of(emitter, scan) orelse return false;
    }

    const head = scan;

    while (scan < close) {
        const kind = emitter.tokens[scan].kind;
        const pathed = kind == .identifier or kind == .keyword or text_is(emitter, scan, "::");
        if (!pathed) break;

        scan = emit.ahead_of(emitter, scan) orelse return false;
    }

    if (scan == head) return true;
    if (scan >= close) return true;
    if (text_is(emitter, scan, "<")) return false;
    if (!text_is(emitter, scan, "!")) return !emitter.tokens[scan].is_punctuation(.paren_open);

    const bracket = emit.ahead_of(emitter, scan) orelse return false;
    if (bracket >= close) return true;
    if (!walk.is_open(emitter.tokens[bracket].kind)) return true;

    const shut = join.closing_of(emitter, bracket) orelse return false;
    return streamed(emitter, bracket, shut);
}

fn opaque_invoked(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    const bang = emit.word_before(emitter, open) orelse return false;
    if (!emitter.tokens[bang].is_punctuation(.bang)) return false;
    return streamed(emitter, open, close);
}

pub fn opaqued(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    return std.sort.binarySearch(u32, emitter.opaques, open, opaque_order) != null;
}

fn opaque_order(wanted: u32, held: u32) std.math.Order {
    assert(wanted < std.math.maxInt(u32));
    assert(held < std.math.maxInt(u32));

    return std.math.order(wanted, held);
}

fn interpolated(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    var scan = open + 1;

    while (scan < close) : (scan += 1) {
        if (walk.is_open(emitter.tokens[scan].kind)) {
            const bang = emit.word_before(emitter, scan) orelse open;
            const invoked_inside = bang > open and emitter.tokens[bang].is_punctuation(.bang);

            if (invoked_inside) {
                scan = join.closing_of(emitter, scan) orelse return false;

                continue;
            }
        }

        if (!text_is(emitter, scan, "#")) continue;

        const next = emit.ahead_of(emitter, scan) orelse return true;
        if (!emitter.tokens[next].is_punctuation(.bracket_open)) return true;
    }

    return false;
}

fn streamed_stops(emitter: *const Emitter, stream: *const Stream, scan: u32, opens: bool) bool {
    assert(scan < emitter.count);
    assert(!stream.lambda);

    if (stream.depth > 0) return false;

    const token = emitter.tokens[scan];
    if (token.is_punctuation(.semicolon)) return true;
    if (token.is_punctuation(.arrow)) return true;
    if (line.word_is(emitter, scan, stream_stops)) return true;
    if (prefix_misplaced(emitter, stream.prior, scan)) return true;
    if (!opens) return false;
    return text_is(emitter, scan, "in");
}

fn prefix_misplaced(emitter: *const Emitter, prior: ?u32, scan: u32) bool {
    assert(scan < emitter.count);

    if (!line.word_is(emitter, scan, stream_prefixes)) return false;
    if (prior) |held| assert(held < emitter.count);

    const held = prior orelse return true;

    assert(held < scan);

    if (emitter.tokens[held].is_punctuation(.comma)) return true;
    return text_is(emitter, held, "=");
}

fn streamed_joins(emitter: *const Emitter, stream: *const Stream, scan: u32) bool {
    assert(scan < emitter.count);
    assert(!stream.lambda);

    if (stream.blocks == 0) {
        if (juxtaposed(emitter, scan)) return true;
    }

    if (!stream.braced()) return false;
    return macro_assigned(emitter, scan);
}

fn juxtaposed(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const token = emitter.tokens[position];
    if (!token.ends_a_value()) return false;
    if (text_is(emitter, position, "'")) return false;
    if (token.kind == .keyword) return false;

    if (emit.back_of(emitter, position)) |held| {
        if (text_is(emitter, held, "'")) return false;
    }

    const ahead = emit.ahead_of(emitter, position) orelse return false;
    const kind = emitter.tokens[ahead].kind;

    if (text_is(emitter, ahead, "if")) return true;

    const valued = kind == .identifier or kind == .number or kind == .string;
    if (!valued) return false;
    return !text_is(emitter, ahead, "'");
}

fn macro_assigned(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.tokens[position].is_punctuation(.assign)) return false;

    const name = emit.back_of(emitter, position) orelse return false;
    if (emitter.tokens[name].kind != .identifier) return false;

    const held = emit.back_of(emitter, name) orelse return false;
    const kind = emitter.tokens[held].kind;
    if (kind == .block_start) return true;
    if (kind == .comment) return true;
    return kind.eql(.{ .punctuation = .comma });
}
