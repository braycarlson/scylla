const std = @import("std");
const assert = std.debug.assert;
const Token = @import("../../syntax/token.zig");
const bind = @import("bind.zig");
const body = @import("body.zig");
const brace = @import("../brace.zig");
const call = @import("call.zig");
const clause = @import("clause.zig");
const comment = @import("comment.zig");
const core = @import("emitter.zig");
const emit = @import("emit.zig");
const join = @import("join.zig");
const line = @import("line.zig");
const list = @import("list.zig");
const semi = @import("semi.zig");
const span = @import("span.zig");
const split = @import("split.zig");
const tern = @import("tern.zig");
const tmpl = @import("tmpl.zig");
const walk = @import("../walk.zig");
const wide = @import("wide.zig");
const wrap = @import("wrap.zig");
const Emitter = core.Emitter;
const clause_words: []const []const u8 = &.{ "do", "else", "finally", "try" };
const method_words: []const []const u8 = &.{ "async", "get", "set", "static" };
const binary_logical_rank: u32 = 3;
const binary_operator_max: u32 = 64;
const chain_scan_max: u32 = 512;

pub fn soled_heavy(emitter: *const Emitter) bool {
    assert(emitter.soled <= core.wrap_depth_max);
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    if (emitter.wraps_owed == 0) return false;
    if (emitter.soled == core.wrap_depth_max) return false;

    const wrapped = emitter.wrapped[emitter.wraps_owed - 1];
    if (!heavy_kind(wrapped.wrap)) return false;
    if (wrapped.floor != call.binary_level_max) return false;
    if (wrapped.depth != emitter.depth) return false;

    const operator = emitter.previous orelse return false;
    if (operator >= wrapped.close) return false;
    if (!span.wrapping_operator(emitter, operator)) return false;

    const stop = soled_tail(emitter, operator) orelse return false;

    if (wrapped.wrap != .valued) return true;
    return !soled_called(emitter, operator, stop);
}

fn heavy_kind(kind: core.Wrap) bool {
    if (kind == .chained) return false;

    return switch (kind) {
        .argued, .bodied, .paired, .valued => true,
        else => false,
    };
}

fn spread_soled(emitter: *const Emitter, position: u32, previous: u32) ?u32 {
    assert(position < emitter.count);
    assert(previous < emitter.count);

    if (!emitter.policy.chain_simples) return null;
    if (!emitter.policy.binary_lines) return null;
    if (!list.spreads(emitter)) return null;
    if (emitter.soled == core.wrap_depth_max) return null;
    if (!span.binary_spread(emitter, position, previous)) return null;
    if (comment.argued_wrapped(emitter)) return null;
    if (wrap.rebalanced_within(emitter, previous)) return null;

    const head, const stop = span.binary_run(emitter, previous) orelse return null;

    if (stop <= previous) return null;
    if (!binary_soled(emitter, head, stop)) return null;
    if (span.binary_last(emitter, head, stop) != previous) return null;
    if (!branch_unindented(emitter, head)) return null;
    return stop;
}

fn branch_unindented(emitter: *const Emitter, head: u32) bool {
    assert(head < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const seat = emit.back_of(emitter, head) orelse return false;
    if (!branch_seated(emitter, seat)) return false;

    const before = emit.back_of(emitter, tern.ternary_test(emitter, seat)) orelse return false;
    const token = emitter.tokens[before];
    if (worded(&.{ "return", "throw" }, token.text(emitter.source))) return false;

    const open = branch_open(emitter, before) orelse return true;
    if (!emitter.tokens[open].is_punctuation(.paren_open)) return true;
    return !list.calling(emitter, open);
}

fn branch_seated(emitter: *const Emitter, seat: u32) bool {
    assert(seat < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const text = emitter.tokens[seat].text(emitter.source);
    if (walk.text_is(text, "?")) return !tern.optional(emitter, seat);
    if (walk.text_is(text, ":")) return tern.ternary(emitter, seat);
    return false;
}

fn branch_open(emitter: *const Emitter, before: u32) ?u32 {
    assert(before < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const token = emitter.tokens[before];
    if (token.is_punctuation(.paren_open)) return before;
    if (token.is_punctuation(.comma)) return bind.enclosing_open(emitter, before);
    return null;
}

pub fn spread_parted(emitter: *const Emitter, position: u32, previous: u32) ?bool {
    assert(position < emitter.count);
    assert(previous < emitter.count);

    if (spread_soled(emitter, position, previous) != null) return false;
    if (!emitter.policy.chain_simples) return null;
    if (!list.spreads(emitter)) return null;
    if (spread_binary(emitter, position, previous)) return true;
    if (span.chain_parts(emitter, position, previous)) return true;
    return null;
}

fn spread_binary(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < emitter.count);

    if (!span.binary_spread(emitter, position, previous)) return false;
    if (comment.argued_wrapped(emitter)) return false;
    return !wrap.rebalanced_within(emitter, previous);
}

pub fn spread_soled_opens(emitter: *Emitter, position: u32, spaced: bool) error{Overflow}!bool {
    assert(position < emitter.count);
    assert(emitter.soled <= core.wrap_depth_max);

    if (!spaced) return false;

    const operator = emitter.previous orelse return false;
    const stop = spread_soled(emitter, position, operator) orelse return false;

    assert(emitter.soled < core.wrap_depth_max);

    emitter.soleds[emitter.soled] = stop;
    emitter.soled += 1;

    try emitter.document.push(.group_open);
    try emitter.document.push(.line);

    return true;
}

pub fn heavy_lined(emitter: *const Emitter) bool {
    assert(emitter.wraps_owed <= core.wrap_depth_max);
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.wraps_owed == 0) return false;

    const top = emitter.wraps_owed - 1;
    const wrapped = emitter.wrapped[top];
    const floor = emitter.wraps_heavy[top];
    if (floor == 0) return false;
    if (!heavy_kind(wrapped.wrap)) return false;
    if (wrapped.depth != emitter.depth) return false;

    const operator = emitter.previous orelse return false;
    if (operator >= wrapped.close) return false;
    if (!call.binary_floored(emitter, comment.shift_head(emitter, operator), floor)) return false;
    return soled_tail(emitter, operator) == null;
}

pub fn soled_joined(emitter: *const Emitter, previous: u32) bool {
    assert(previous < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.binary_lines) return false;

    const head, const stop = span.binary_owned(emitter, previous) orelse return false;
    if (!binary_soled(emitter, head, stop)) return false;
    if (wrap.nest_bodied(emitter, previous, head, stop)) return false;
    return !span.binary_wide(emitter, head, stop);
}

pub fn soled_close(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position <= emitter.count);

    while (emitter.soled > 0) {
        if (position <= emitter.soleds[emitter.soled - 1]) break;

        emitter.soled -= 1;

        try emitter.document.push(.group_close);
    }

    assert(emitter.soled <= core.wrap_depth_max);
}

pub fn listed(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    if (core.memo_found(emitter, .listed, position, 0)) |answer| return answer == 1;

    const held = listed_scanned(emitter, position);

    core.memo_store(emitter, .listed, position, 0, @intFromBool(held));

    return held;
}

fn listed_scanned(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    const kind = emitter.tokens[position].kind;
    const bracketed = kind.eql(.{ .punctuation = .bracket_close });
    const open = emit.opened(emitter, position) orelse return false;
    const before = comment.back(emitter, open) orelse return bracketed;
    const held = emitter.tokens[before];

    assert(open < position);
    assert(before < open);

    if (kind == .block_end) {
        if (wide.objected(emitter, before, held)) return true;
        if (span.type_framed(emitter, open)) return true;
        if (span.angled_object(emitter, open)) return true;
        return split.specifier_open(emitter, open);
    }

    if (bracketed) {
        if (list.mapped_key(emitter, open)) return false;
        return listed_bracket(emitter, before, held);
    }

    return listed_paren(emitter, position, open, before, held);
}

fn listed_bracket(emitter: *const Emitter, before: u32, held: Token) bool {
    assert(before < emitter.count);
    assert(held.end() <= emitter.source.len);

    if (emit.is_dot(emitter, before)) return false;
    if (line.word_is(emitter, before, emitter.policy.member_words)) return false;

    const keyword = held.kind == .keyword;
    const operand = line.word_is(emitter, before, emitter.policy.operand_words);
    const keyworded = emitter.policy.chain_simples and keyword and !operand;
    const holed = walk.substituting(emitter.source, held);
    const blocked = held.kind == .block_end and listed_bodied(emitter, before);

    if (keyworded) return true;
    if (holed) return true;
    if (blocked) return true;
    return !held.ends_a_value() and !line.nonnull_ended(emitter, before);
}

fn listed_bodied(emitter: *const Emitter, before: u32) bool {
    assert(before < emitter.count);
    assert(emitter.tokens[before].kind == .block_end);

    const opener = emitter.brackets.open_of(before) orelse return false;

    assert(opener < before);

    return body.bodied_brace(emitter, opener);
}

fn listed_paren(emitter: *const Emitter, position: u32, open: u32, before: u32, held: Token) bool {
    assert(open < position);
    assert(before < open);
    assert(held.length <= std.math.maxInt(u32) - held.offset);

    const ended = held.kind == .block_end and listed_ended(emitter, before);
    const bodied = clause.header_closed(emitter, before);

    if (list.signature_paren(emitter, open)) return true;
    if (list.calling(emitter, open)) return true;
    if (quoted_method(emitter, before)) return true;
    if (list.generator_paren(emitter, before)) return true;
    if (split.headed(emitter, open)) return true;
    if (span.spread_arrows(emitter, open)) return true;

    const closed = walk.is_close(held.kind) and !ended and !bodied;
    if (closed) return true;
    if (call.class_newed(emitter, before)) return true;
    return wide.tupled(emitter, open, position);
}

fn listed_ended(emitter: *const Emitter, before: u32) bool {
    assert(before < emitter.count);
    assert(emitter.tokens[before].kind == .block_end);

    if (semi.statement_braced(emitter, before)) return true;
    if (semi.declares_a_body(emitter, before)) return true;

    const opener = emitter.brackets.open_of(before) orelse return false;

    assert(opener < before);

    return clause_brace(emitter, opener);
}

fn clause_brace(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    const before = emit.back_of(emitter, open) orelse return false;
    const token = emitter.tokens[before];

    assert(before < open);

    if (worded(clause_words, token.text(emitter.source))) return true;
    if (!token.is_punctuation(.paren_close)) return false;

    const paren = emitter.brackets.open_of(before) orelse return false;

    assert(paren < before);

    return split.headed(emitter, paren);
}

pub fn quoted_method(emitter: *const Emitter, name: u32) bool {
    assert(name < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.tokens[name].kind != .string) return false;
    if (emitter.depth == 0) return false;
    if (line.frame(emitter).kind != .block_start) return false;

    const held = join.coded_before(emitter, name) orelse return false;
    const kind = emitter.tokens[held].kind;

    assert(held < name);

    const coded = switch (kind) {
        .block_end, .block_start, .keyword => true,
        .punctuation => |punctuation| punctuation == .comma or punctuation == .semicolon,
        .comment, .identifier, .newline, .number, .string => false,
    };

    if (coded) return true;
    return line.word_is(emitter, held, method_words);
}

fn worded(words: []const []const u8, text: []const u8) bool {
    assert(words.len > 0);
    assert(text.len <= std.math.maxInt(u32));

    for (words) |word| {
        if (walk.text_eql(word, text)) return true;
    }

    return false;
}

pub fn heavy_armed(emitter: *Emitter) error{Overflow}!void {
    assert(emitter.wraps_owed > 0);
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    const top = emitter.wraps_owed - 1;
    if (emitter.wrapped[top].wrap != .argued) return;
    if (emitter.wraps_armed[top]) return;

    emitter.wraps_armed[top] = true;

    try line.opens_broken(emitter);
}

pub fn soled_heavy_lined(emitter: *Emitter) error{Overflow}!void {
    assert(emitter.wraps_owed > 0);
    assert(emitter.soled <= core.wrap_depth_max);

    try heavy_armed(emitter);
    try soled_heavy_open(emitter);
    try emitter.document.push(.line);
}

fn soled_heavy_open(emitter: *Emitter) error{Overflow}!void {
    assert(emitter.soled <= core.wrap_depth_max);

    const operator = emitter.previous orelse return error.Overflow;
    const stop = soled_tail(emitter, operator) orelse return error.Overflow;

    assert(emitter.soled < core.wrap_depth_max);

    emitter.soleds[emitter.soled] = stop;
    emitter.soled += 1;

    try emitter.document.push(.group_open);
}

fn soled_tail(emitter: *const Emitter, prior: u32) ?u32 {
    assert(prior < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.binary_lines) return null;

    const head, const stop = span.binary_run(emitter, prior) orelse return null;

    if (stop <= prior) return null;
    if (!binary_soled(emitter, head, stop)) return null;

    const root = span.binary_last(emitter, head, stop) orelse return null;
    if (root < prior) return null;

    if (prior < root) {
        const end = emit.back_of(emitter, root) orelse return null;
        if (!binary_soled(emitter, head, end)) return null;
        return end;
    }

    return stop;
}

pub fn comma_denied(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.chain_simples) return false;
    if (!emitter.tokens[position].is_punctuation(.paren_close)) return false;

    const open = emit.opened(emitter, position) orelse return false;

    assert(open < position);

    if (split.headed(emitter, open)) return true;
    if (list.paren_grouped(emitter, open, position)) return true;
    if (call.imported(emitter, open)) return true;
    if (cast_commented(emitter, open)) return true;

    const held = emit.word_before(emitter, open) orelse return false;
    if (emitter.tokens[held].kind != .block_end) return false;
    return semi.declares_a_body(emitter, held);
}

pub fn cast_commented(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.tokens[open].is_punctuation(.paren_open));

    const before = emit.back_of(emitter, open) orelse return false;
    const token = emitter.tokens[before];
    if (token.kind != .comment) return false;

    const text = token.text(emitter.source);
    if (!std.mem.startsWith(u8, text, "/**")) return false;
    return std.mem.find(u8, text, "@type") != null or std.mem.find(u8, text, "@satisfies") != null;
}

pub fn soled_open(emitter: *Emitter) error{Overflow}!void {
    assert(emitter.soled <= core.wrap_depth_max);
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    if (emitter.soled == core.wrap_depth_max) return;
    if (!comment.binary_wrapped(emitter)) return;

    const previous = emitter.previous orelse return;
    if (emitter.tokens[previous].is_punctuation(.comma)) return;

    const stop = soled_tail(emitter, previous) orelse return;

    emitter.soleds[emitter.soled] = stop;
    emitter.soled += 1;

    try emitter.document.push(.group_open);
}

pub fn binary_tested(emitter: *const Emitter, previous: u32) bool {
    assert(previous < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    _, const stop = span.binary_run(emitter, previous) orelse return false;
    const held = emit.ahead_of(emitter, stop) orelse return false;
    const question = walk.text_is(emitter.tokens[held].text(emitter.source), "?");
    if (!question) return false;
    return !tern.optional(emitter, held);
}

pub fn binary_test_indents(emitter: *const Emitter, previous: u32) bool {
    assert(previous < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const head, _ = span.binary_run(emitter, previous) orelse return false;
    const before = emit.back_of(emitter, head) orelse return false;
    const token = emitter.tokens[before];
    if (worded(&.{ "return", "throw" }, token.text(emitter.source))) return true;
    if (token.is_punctuation(.paren_open)) return binary_test_paren(emitter, before);
    if (!token.is_punctuation(.comma)) return false;
    if (emitter.depth == 0) return false;
    return list.calling(emitter, line.frame(emitter).open);
}

fn binary_test_paren(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.tokens[open].is_punctuation(.paren_open));

    if (list.calling(emitter, open)) return true;

    const close = join.closing_of(emitter, open) orelse return false;
    const after = emit.ahead_of(emitter, close) orelse return false;

    return emitter.tokens[after].is_punctuation(.paren_open);
}

pub fn run_continued(emitter: *const Emitter, previous: u32) bool {
    assert(previous < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const head, const stop = span.binary_run(emitter, previous) orelse return false;
    const seam = emitter.line_before;
    if (seam <= head) return false;
    if (seam > stop) return false;

    var scan = head;

    for (0..chain_scan_max) |_| {
        const after = emit.ahead_of(emitter, scan) orelse return false;

        if (after >= seam) {
            if (after != seam) return false;

            const found = emit.back_of(emitter, after) orelse return false;
            return span.wrapping_operator(emitter, found);
        }

        scan = after;

        if (walk.is_open(emitter.tokens[after].kind)) {
            scan = join.closing_of(emitter, after) orelse return false;
        }
    }

    return false;
}

pub fn binary_soled(emitter: *const Emitter, head: u32, stop: u32) bool {
    assert(head <= stop);
    assert(stop < emitter.count);

    var ranks: [binary_operator_max]struct { u32, u32 } = @splat(.{ 0, 0 });
    const count = span.binary_ranked(emitter, head, stop, &ranks) orelse return false;

    assert(count <= binary_operator_max);

    const least = binary_least(ranks[0..count]);
    const logical = least <= binary_logical_rank;
    var matched: u32 = 0;

    for (ranks[0..count]) |entry| {
        const ranked_logical = entry[1] <= binary_logical_rank;

        if (ranked_logical == logical) matched += 1;
    }

    if (matched != 1) return false;
    if (binary_kinded(emitter, head, stop, logical)) return false;
    return !binary_parented(emitter, head, stop, logical);
}

fn binary_least(ranks: []const struct { u32, u32 }) u32 {
    assert(ranks.len <= binary_operator_max);

    if (ranks.len == 0) return 0;

    var least: u32 = std.math.maxInt(u32);

    for (ranks) |entry| {
        least = @min(least, entry[1]);
    }

    assert(least < std.math.maxInt(u32));

    return least;
}

fn binary_parented(emitter: *const Emitter, head: u32, stop: u32, logical: bool) bool {
    assert(head <= stop);
    assert(stop < emitter.count);

    if (!parented_paired(emitter, head, stop)) return false;

    if (parented_before(emitter, head)) |held| {
        if (parented_ranked(emitter, held, logical)) return true;
    }

    const tail = parented_after(emitter, stop) orelse return false;
    return parented_ranked(emitter, tail, logical);
}

fn parented_paired(emitter: *const Emitter, head: u32, stop: u32) bool {
    assert(head <= stop);
    assert(stop < emitter.count);

    const open = emit.back_of(emitter, head) orelse return false;
    if (!emitter.tokens[open].is_punctuation(.paren_open)) return false;

    const after = emit.ahead_of(emitter, stop);

    if (emitter.brackets.close_of(open)) |close| {
        if (after != close) return false;
    } else {
        if (after != null) return false;
    }

    return !list.calling(emitter, open);
}

fn parented_before(emitter: *const Emitter, head: u32) ?u32 {
    assert(head < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const held = emit.back_of(emitter, head) orelse return null;
    if (!emitter.tokens[held].is_punctuation(.paren_open)) return null;
    return emit.back_of(emitter, held);
}

fn parented_after(emitter: *const Emitter, stop: u32) ?u32 {
    assert(stop < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const held = emit.ahead_of(emitter, stop) orelse return null;
    if (!emitter.tokens[held].is_punctuation(.paren_close)) return null;
    return emit.ahead_of(emitter, held);
}

fn parented_ranked(emitter: *const Emitter, held: u32, logical: bool) bool {
    assert(held < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const rank = span.binary_rank(emitter, held) orelse return false;
    return (rank <= binary_logical_rank) == logical;
}

fn binary_kinded(emitter: *const Emitter, head: u32, stop: u32, logical: bool) bool {
    assert(head <= stop);
    assert(stop < emitter.count);

    const operator = span.binary_last(emitter, head, stop) orelse return false;

    if (emit.ahead_of(emitter, operator)) |held| {
        if (held <= stop) {
            if (binary_familied(emitter, held, stop, logical)) return true;
        }
    }

    const tail = emit.back_of(emitter, operator) orelse return false;
    if (tail < head) return false;
    return binary_familied(emitter, head, tail, logical);
}

pub fn binary_familied(emitter: *const Emitter, head: u32, stop: u32, logical: bool) bool {
    assert(head < emitter.count);
    assert(stop < emitter.count);

    var from = head;
    var to = stop;

    while (emitter.tokens[from].is_punctuation(.paren_open)) {
        if (emitter.brackets.close_of(from) != to) break;

        const inner = emit.ahead_of(emitter, from) orelse return false;
        const outer = emit.back_of(emitter, to) orelse return false;

        if (inner >= to) return false;
        if (outer <= from) return false;

        assert(inner > from);
        assert(outer < to);

        from = inner;
        to = outer;
    }

    const rank = familied_rank(emitter, from, to) orelse return false;
    return (rank <= binary_logical_rank) == logical;
}

fn familied_rank(emitter: *const Emitter, from: u32, to: u32) ?u32 {
    assert(from < emitter.count);
    assert(to < emitter.count);

    var depth: u32 = 0;
    var least: ?u32 = null;
    var scan = from;

    while (scan <= to) {
        const skipped = tmpl.template_body(emitter, scan) orelse span.jsx_body(emitter, scan);

        if (skipped) |end| {
            assert(end >= scan);

            scan = end + 1;

            continue;
        }

        const kind = emitter.tokens[scan].kind;

        if (walk.is_open(kind)) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            depth -|= 1;
        } else if (depth == 0) {
            if (binary_looser(emitter, scan)) return null;

            if (span.binary_rank(emitter, scan)) |rank| {
                least = if (least) |held| @min(held, rank) else rank;
            }
        } else {}

        scan += 1;
    }

    return least;
}

fn binary_looser(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const token = emitter.tokens[position];
    if (token.is_punctuation(.assign)) return true;
    if (token.is_punctuation(.comma)) return true;
    return worded(&.{ "=>", "?", ":" }, token.text(emitter.source));
}

pub fn body_operand(emitter: *const Emitter, head: u32, arrow: u32) bool {
    assert(head < emitter.count);
    assert(arrow < emitter.count);

    const operator = emit.back_of(emitter, head) orelse return false;
    if (!span.wrapping_operator(emitter, operator)) return false;

    const run_head, _ = span.binary_run(emitter, operator) orelse return false;
    return emit.ahead_of(emitter, arrow) == run_head;
}

fn soled_called(emitter: *const Emitter, operator: u32, stop: u32) bool {
    assert(operator < stop);
    assert(stop < emitter.count);

    var scan = operator + 1;

    while (scan <= stop) {
        const kind = emitter.tokens[scan].kind;

        if (kind.eql(.{ .punctuation = .paren_open })) {
            if (list.calling(emitter, scan)) return true;
        }

        if (walk.is_open(kind)) {
            const close = join.closing_of(emitter, scan) orelse return false;

            assert(close > scan);

            scan = close;
        }

        scan += 1;
    }

    return false;
}

pub fn binary_rank_first(emitter: *const Emitter, head: u32, stop: u32, previous: u32) bool {
    assert(head <= stop);
    assert(previous < emitter.count);

    var ranks: [binary_operator_max]struct { u32, u32 } = @splat(.{ 0, 0 });
    const ranked = span.binary_ranked(emitter, head, stop, &ranks);
    const wanted = span.binary_rank(emitter, previous);
    const count = ranked orelse return false;
    const rank = wanted orelse return false;

    assert(count <= binary_operator_max);

    for (ranks[0..count]) |entry| {
        if (entry[1] != rank) continue;
        if (entry[0] != previous) return false;
        return emitter.line_before < previous;
    }

    return false;
}
