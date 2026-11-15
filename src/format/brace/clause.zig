const std = @import("std");
const assert = std.debug.assert;
const Token = @import("../../syntax/token.zig");
const body = @import("body.zig");
const brace = @import("../brace.zig");
const call = @import("call.zig");
const comment = @import("comment.zig");
const core = @import("emitter.zig");
const edge = @import("edge.zig");
const emit = @import("emit.zig");
const join = @import("join.zig");
const lead = @import("lead.zig");
const line = @import("line.zig");
const link = @import("link.zig");
const span = @import("span.zig");
const split = @import("split.zig");
const walk = @import("../walk.zig");
const wide = @import("wide.zig");
const Emitter = core.Emitter;
const clause_braced_bodies = [_][]const u8{ "do", "for", "if", "switch", "try", "while", "with" };
const clause_carriers = [_][]const u8{ "do", "if", "try" };
const else_walk_max: u32 = 64;
const opener_depth_max: u32 = 30;

pub fn parted(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < position);

    if (!emitter.policy.clause_lines) return false;

    if (clause_follows(emitter, position, previous)) {
        if (clause_over(emitter, previous, previous)) return true;
        return word_wide(emitter, position);
    }

    if (!emitter.tokens[previous].is_punctuation(.paren_close)) return false;

    const head = clause_head(emitter, previous) orelse return false;

    if (!clause_bodied(emitter, position)) return false;

    const open = emit.opened(emitter, previous) orelse previous;
    if (!seated(emitter, open)) return true;
    return clause_over(emitter, head, previous);
}

fn clause_follows(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < position);

    if (!body_worded_at(emitter, previous)) return false;
    if (!clause_bodied(emitter, position)) return false;
    if (!line.word_is(emitter, position, emitter.policy.clause_heads)) return true;
    return do_worded(emitter, previous);
}

fn word_wide(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.policy.clause_lines);

    const end = call.valued_semicolon(emitter, position) orelse return false;

    assert(end < emitter.count);

    return span.header_over(emitter, end, 0);
}

pub fn else_level(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.chain_simples) return null;
    if (!emitter.policy.header_parens) return null;

    if (line.word_is(emitter, position, &.{"else"})) {
        const opener = else_if(emitter, position) orelse return null;
        return line.level_at(emitter, opener);
    }

    if (line.word_is(emitter, position, &.{"while"})) {
        const opener = clause_opener(emitter, position, true) orelse return null;
        return line.level_at(emitter, opener);
    }

    return null;
}

pub fn follows_its_block(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const word = emitter.tokens[position].text(emitter.source);
    const head = emit.back_of(emitter, emitter.closed.open);

    if (walk.text_is(word, "while")) {
        const held = head orelse return false;
        return line.word_is(emitter, held, &.{"do"});
    }

    const heads = follows_heads(word) orelse return true;
    const held = head orelse return false;
    const header = follows_header(emitter, held);

    assert(header <= held);

    return line.word_is(emitter, header, heads);
}

fn follows_header(emitter: *const Emitter, held: u32) u32 {
    assert(held < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.tokens[held].is_punctuation(.paren_close)) return held;

    const open = emitter.brackets.open_of(held) orelse return held;

    assert(open < held);

    return emit.back_of(emitter, open) orelse held;
}

fn follows_heads(word: []const u8) ?[]const []const u8 {
    assert(word.len <= std.math.maxInt(u32));

    if (walk.text_is(word, "catch")) return &.{"try"};
    if (walk.text_is(word, "else")) return &.{"if"};
    if (walk.text_is(word, "finally")) return &.{ "catch", "try" };
    return null;
}

fn else_if(emitter: *const Emitter, word: u32) ?u32 {
    assert(word < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    return clause_opener(emitter, word, false);
}

fn clause_opener(emitter: *const Emitter, word: u32, looped: bool) ?u32 {
    assert(word < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var owed: u32 = @intFromBool(looped);
    var depth: u32 = 1;
    var head = body_head(emitter, word) orelse return null;

    for (0..else_walk_max) |_| {
        if (depth == opener_depth_max) return null;

        assert(depth < opener_depth_max);

        const before = join.coded_before(emitter, head) orelse return null;

        if (line.word_is(emitter, before, &.{"else"})) {
            owed <<= 1;
            depth += 1;
            head = body_head(emitter, before) orelse return null;

            continue;
        }

        if (do_worded(emitter, before)) {
            if (owed & 1 == 0) return null;

            owed >>= 1;
            depth -= 1;

            if (depth == 0) return before;

            head = before;

            continue;
        }

        if (compound_head(emitter, head, before)) |found| {
            head = found;

            continue;
        }

        if (!emitter.tokens[before].is_punctuation(.paren_close)) return null;

        const found = clause_head(emitter, before) orelse return null;

        if (do_tailed(emitter, found)) {
            owed = (owed << 1) | 1;
            depth += 1;
            head = body_head(emitter, found) orelse return null;

            continue;
        }

        if (line.word_is(emitter, found, &.{"if"})) {
            if (owed & 1 == 0) {
                owed >>= 1;
                depth -= 1;

                if (depth == 0) return found;
            }
        }

        head = found;
    }

    return null;
}

fn do_tailed(emitter: *const Emitter, word: u32) bool {
    assert(word < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!line.word_is(emitter, word, &.{"while"})) return false;

    const held = join.coded_before(emitter, word) orelse return false;
    const kind = emitter.tokens[held].kind;
    if (kind == .block_end) return true;
    return kind.eql(.{ .punctuation = .semicolon });
}

fn body_head(emitter: *const Emitter, word: u32) ?u32 {
    assert(word < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var head = consequent_head(emitter, word) orelse return null;

    for (0..opener_depth_max) |_| {
        const opens = line.word_is(emitter, head, &.{"else"}) or do_worded(emitter, head);
        if (!opens) break;

        head = line.coding(emitter, head) orelse return null;
    }

    assert(head < emitter.count);

    return head;
}

fn compound_head(emitter: *const Emitter, head: u32, before: u32) ?u32 {
    assert(head < emitter.count);
    assert(before < head);

    if (emitter.tokens[head].kind != .block_start) return null;
    if (line.word_is(emitter, before, &.{"try"})) return before;

    const word = compound_word(emitter, before) orelse return null;
    if (!line.word_is(emitter, word, &.{ "catch", "finally" })) return null;
    return block_before(emitter, word);
}

fn compound_word(emitter: *const Emitter, before: u32) ?u32 {
    assert(before < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.tokens[before].is_punctuation(.paren_close)) return before;

    const open = emitter.brackets.open_of(before) orelse return null;
    return join.coded_before(emitter, open);
}

fn block_before(emitter: *const Emitter, word: u32) ?u32 {
    assert(word < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const close = join.coded_before(emitter, word) orelse return null;
    if (emitter.tokens[close].kind != .block_end) return null;
    return emitter.brackets.open_of(close);
}

fn consequent_head(emitter: *const Emitter, word: u32) ?u32 {
    assert(word < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const held = join.coded_before(emitter, word) orelse return null;
    const kind = emitter.tokens[held].kind;
    if (kind == .block_end) return emitter.brackets.open_of(held);
    if (kind.eql(.{ .punctuation = .semicolon })) return edge.statement_head(emitter, held);
    return null;
}

pub fn header_bodied_gap(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < emitter.count);

    if (!header_closed(emitter, previous)) return false;
    return clause_bodied(emitter, position);
}

pub fn header_closed(emitter: *const Emitter, close: u32) bool {
    assert(close < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.clause_lines) return false;
    if (!emitter.tokens[close].is_punctuation(.paren_close)) return false;
    return clause_head(emitter, close) != null;
}

pub fn bounded(emitter: *const Emitter, position: u32, kind: Token.Kind) bool {
    assert(position < emitter.count);
    assert(emitter.claused_depth <= brace.nest_depth_max);

    if (!emitter.policy.clause_ends) return false;
    if (kind != .block_start) return false;
    if (!emitter.claused) return false;
    if (emitter.depth != emitter.claused_depth) return false;
    return emitter.brackets.angles_at(position) == 0;
}

pub fn within(emitter: *const Emitter) bool {
    assert(emitter.depth <= brace.nest_depth_max);
    assert(emitter.claused_depth <= brace.nest_depth_max);

    if (!emitter.policy.clause_lines) return false;
    if (!emitter.claused) return false;
    return emitter.depth == emitter.claused_depth;
}

pub fn value_parted(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < position);

    if (emitter.line_first > previous) return false;
    return value_claused(emitter, emitter.line_first, position);
}

pub fn value_level(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);

    if (!value_claused(emitter, emitter.line_before, position)) return null;
    assert(emitter.printed + 1 < std.math.maxInt(u32));

    return emitter.printed + 1;
}

fn value_claused(emitter: *const Emitter, head: u32, equals: u32) bool {
    assert(head < emitter.count);
    assert(equals < emitter.count);

    if (emitter.policy.clause_values.len == 0) return false;
    if (!emitter.tokens[equals].is_punctuation(.assign)) return false;
    if (head >= equals) return false;
    if (emitter.brackets.angles_at(equals) > 0) return false;
    if (!value_item(emitter, head, equals)) return false;
    return value_clause(emitter, equals);
}

fn value_item(emitter: *const Emitter, head: u32, equals: u32) bool {
    assert(head < equals);
    assert(equals < emitter.count);

    var scan = head;

    for (0..core.define_scan_max) |_| {
        if (scan >= equals) return false;
        if (line.word_is(emitter, scan, emitter.policy.clause_values)) return true;

        const held = emit.ahead_of(emitter, scan) orelse return false;

        assert(held > scan);

        scan = held;
    }

    return false;
}

fn value_clause(emitter: *const Emitter, equals: u32) bool {
    assert(equals < emitter.count);
    assert(emitter.tokens[equals].is_punctuation(.assign));

    var scan = emit.ahead_of(emitter, equals) orelse return false;
    var depth: u32 = 0;

    for (0..core.define_scan_max) |_| {
        const kind = emitter.tokens[scan].kind;

        if (depth == 0) {
            if (kind.eql(.{ .punctuation = .semicolon })) return false;
        }

        if (walk.is_open(kind)) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            if (depth == 0) return false;

            depth -= 1;
        } else if (depth == 0) {
            const worded = line.word_is(emitter, scan, emitter.policy.clause_words);
            if (worded) return parted_before(emitter, scan);
        } else {}

        scan = emit.ahead_of(emitter, scan) orelse return false;
    }

    return false;
}

fn parted_before(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const held = emit.back_of(emitter, position) orelse return false;
    const from = emitter.tokens[held].end();
    const to = emitter.tokens[position].offset;

    return body.parted_by(emitter, from, to) > 0;
}

pub fn seated(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.clause_lines) return false;
    if (!split.headed(emitter, open)) return false;

    const close = join.closing_of(emitter, open) orelse return false;
    const after = emit.ahead_of(emitter, close) orelse return false;
    if (!clause_bodied(emitter, after)) return false;

    const head = emit.word_before(emitter, open) orelse return false;

    if (span.spread_breaks(emitter, open, close)) return false;
    return clause_columns(emitter, head, close + 1) <= emitter.options.line_width;
}

pub fn seated_joined(emitter: *const Emitter) bool {
    assert(emitter.depth <= brace.nest_depth_max);
    assert(emitter.count == emitter.tokens.len);

    var index = emitter.depth;

    while (index > 0) {
        index -= 1;

        const frame = emitter.nest[index];
        if (!frame.kind.eql(.{ .punctuation = .paren_open })) continue;
        if (seated(emitter, frame.open)) return true;
    }

    return false;
}

fn clause_head(emitter: *const Emitter, close: u32) ?u32 {
    assert(close < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const open = emit.opened(emitter, close) orelse return null;
    if (!split.headed(emitter, open)) return null;
    return emit.word_before(emitter, open);
}

fn clause_bodied(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const kind = emitter.tokens[position].kind;
    if (kind == .block_start) return false;
    if (kind == .comment) return false;
    return !kind.eql(.{ .punctuation = .semicolon });
}

fn clause_over(emitter: *const Emitter, head: u32, close: u32) bool {
    assert(head <= close);
    assert(close < emitter.count);

    const after = emit.ahead_of(emitter, close);
    const braced = if (after) |held| line.word_is(emitter, held, &clause_braced_bodies) else false;

    if (braced) {
        if (clause_broken(emitter, close)) return true;
    }

    const end = clause_end(emitter, head) orelse return false;
    const close_end = emitter.tokens[close].end();
    const welded = if (after) |held| close_end == emitter.tokens[held].offset else false;

    if (clause_broken(emitter, close)) return true;

    const bound_width = bound(emitter, head, close) * emitter.options.indent_width;
    const columns = clause_columns(emitter, head, end + 1) + @intFromBool(welded);

    return columns > emitter.options.line_width + bound_width;
}

pub fn header_aligns(emitter: *const Emitter) u32 {
    assert(emitter.depth <= brace.nest_depth_max);
    assert(emitter.count == emitter.tokens.len);

    return lead.ternary_align_columns(emitter);
}

pub fn base(emitter: *const Emitter) u32 {
    assert(emitter.levels <= core.line_level_max);
    assert(emitter.depth <= brace.nest_depth_max);

    return emitter.levels + @intFromBool(within(emitter));
}

pub fn body_worded_at(emitter: *const Emitter, word: u32) bool {
    assert(word < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!line.statement_level(emitter)) return false;
    if (do_worded(emitter, word)) return true;
    return else_worded(emitter, word);
}

fn else_worded(emitter: *const Emitter, word: u32) bool {
    assert(word < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!line.word_is(emitter, word, &.{"else"})) return false;

    const held = emit.back_of(emitter, word) orelse return false;
    const kind = emitter.tokens[held].kind;
    if (kind == .block_end) return true;
    return kind.eql(.{ .punctuation = .semicolon });
}

fn do_worded(emitter: *const Emitter, word: u32) bool {
    assert(word < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!line.word_is(emitter, word, &.{"do"})) return false;

    const held = emit.back_of(emitter, word) orelse return true;
    return !emit.is_dot(emitter, held);
}

pub fn started(emitter: *const Emitter) bool {
    assert(emitter.depth <= brace.nest_depth_max);
    assert(emitter.count == emitter.tokens.len);

    const held = line.coded(emitter) orelse return false;
    const kind = emitter.tokens[held].kind;
    if (kind == .block_end) return true;
    if (kind.eql(.{ .punctuation = .colon })) return true;
    return kind.eql(.{ .punctuation = .semicolon });
}

pub fn run_stepped(
    emitter: *const Emitter,
    wrapped: bool,
    seat: ?u32,
    opened: u32,
    head: u32,
) bool {
    assert(head < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (run_claused(emitter, seat, head)) return false;
    if (wrapped) return true;

    const held = seat orelse return false;
    return held >= opened;
}

fn run_claused(emitter: *const Emitter, seat: ?u32, head: u32) bool {
    assert(head < emitter.count);
    assert(emitter.count == emitter.tokens.len);
    if (seat) |held| assert(held < emitter.count);

    const open = seat orelse return false;
    const after = emit.ahead_of(emitter, open) orelse return false;
    if (after != head) return false;
    return comment.header_clauses(emitter, open);
}

pub fn else_bodied(emitter: *const Emitter, position: u32, previous: u32) ?u32 {
    assert(position < emitter.count);
    assert(previous < emitter.count);

    if (!emitter.policy.clause_lines) return null;
    if (!line.word_is(emitter, previous, &.{ "do", "else" })) return null;
    if (!clause_bodied(emitter, position)) return null;

    if (emit.back_of(emitter, previous)) |held| {
        if (emit.is_dot(emitter, held)) return null;
    }

    const level = line.level_at(emitter, previous) orelse return null;
    assert(level + 1 < std.math.maxInt(u32));

    return level + 1;
}

pub fn bound(emitter: *const Emitter, head: u32, close: u32) u32 {
    assert(head <= close);
    assert(emitter.listed <= emitter.binders.len);

    if (emitter.listed == 0) return 0;

    const binder = emitter.binders[emitter.listed - 1].start;
    if (binder < head) return 0;
    return @intFromBool(binder < close);
}

fn clause_broken(emitter: *const Emitter, close: u32) bool {
    assert(close < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const after = emit.ahead_of(emitter, close);
    const carries = if (after) |held| line.word_is(emitter, held, &clause_carriers) else false;
    var depth: u32 = 0;
    var loops: u32 = 0;
    var scan = close;

    for (0..core.define_scan_max) |_| {
        scan = emit.ahead_of(emitter, scan) orelse return false;

        const kind = emitter.tokens[scan].kind;

        if (body.parts(emitter, scan)) return true;

        if (walk.is_open(kind)) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            if (depth == 0) return false;

            depth -= 1;
        } else if (depth == 0) {
            if (do_worded(emitter, scan)) {
                loops += 1;
            } else if (kind.eql(.{ .punctuation = .semicolon })) {
                const stopped = clause_stopped(emitter, scan, close, loops, carries);
                if (stopped) |result| return result;
            } else {}
        } else {}
    }

    return false;
}

fn clause_stopped(emitter: *const Emitter, end: u32, close: u32, loops: u32, carries: bool) ?bool {
    assert(close < end);
    assert(end < emitter.count);

    const after = emit.ahead_of(emitter, end);

    if (loops > 0) {
        if (after) |held| {
            if (line.word_is(emitter, held, &.{"while"})) return true;
        }
    }

    if (else_inside(emitter, end, close)) return true;
    if (!carries) return false;

    const held = after orelse return false;
    if (!line.word_is(emitter, held, &.{"else"})) return false;
    return null;
}

fn else_inside(emitter: *const Emitter, end: u32, close: u32) bool {
    assert(close < end);
    assert(end < emitter.count);

    const after = emit.ahead_of(emitter, end) orelse return false;
    if (!line.word_is(emitter, after, &.{"else"})) return false;

    const found = else_if(emitter, after) orelse return false;
    return found > close;
}

fn clause_columns(emitter: *const Emitter, head: u32, end: u32) u32 {
    assert(head < end);
    assert(end <= emitter.count);

    const level = @max(emitter.printed, link.led_level(emitter));
    const columns = wide.flat_columns(emitter, head, end);
    const returned = level * emitter.options.indent_width + header_aligns(emitter) + columns;

    assert(returned < std.math.maxInt(u32));

    return returned;
}

fn clause_end(emitter: *const Emitter, head: u32) ?u32 {
    assert(head < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var depth: u32 = 0;
    var scan = head;

    for (0..core.define_scan_max) |_| {
        const kind = emitter.tokens[scan].kind;

        if (depth == 0) {
            if (kind.eql(.{ .punctuation = .semicolon })) return scan;
        }

        if (walk.is_open(kind)) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            if (depth == 0) return null;

            depth -= 1;
        } else {}

        scan = emit.ahead_of(emitter, scan) orelse return null;
    }

    return null;
}
