const std = @import("std");
const assert = std.debug.assert;
const bind = @import("bind.zig");
const body = @import("body.zig");
const brace = @import("../brace.zig");
const call = @import("call.zig");
const comment = @import("comment.zig");
const core = @import("emitter.zig");
const emit = @import("emit.zig");
const join = @import("join.zig");
const jsx = @import("jsx.zig");
const lead = @import("lead.zig");
const line = @import("line.zig");
const link = @import("link.zig");
const list = @import("list.zig");
const own = @import("own.zig");
const sole = @import("sole.zig");
const span = @import("span.zig");
const split = @import("split.zig");
const tern = @import("tern.zig");
const tmpl = @import("tmpl.zig");
const walk = @import("../walk.zig");
const wide = @import("wide.zig");
const Emitter = core.Emitter;
const Span = @import("../../stdx/bounded/span.zig");
const binary_operator_max: u32 = 64;
const case_scan_max: u32 = 256;
const cast_ends: []const []const u8 = &.{ "false", "null", "super", "this", "true" };
const cast_heads: []const []const u8 = &.{ "async", "class", "function" };
const cast_scan_max: u32 = 256;
const cast_stops: []const []const u8 = &.{ ",", ";", "=>" };
const cast_words: []const []const u8 = &.{ "as", "satisfies" };
const clause_scan_max: u32 = 1024;
const enum_scan_max: u32 = 256;
const logical_level_max: u32 = 3;
const logical_words: []const []const u8 = &.{ "&&", "||", "??" };
const unary_words: []const []const u8 = &.{ "!", "+", "-", "~", "await", "typeof", "void" };

pub fn wraps(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    if (emitter.wraps_owed == core.wrap_depth_max) return;
    if (tmpl.holed(emitter)) return;
    if (tmpl.template_piece(emitter, position)) return;

    const close, const wrap, const operand = wraps_run(emitter, position) orelse return;

    const flat = operand == core.nest_none and wrap == .paired and
        own.grouped_flat(emitter, position);

    const nest = if (flat) core.nest_flat else operand;

    try wrap_opened(emitter, position, close, wrap, nest);

    for (0..core.wrap_depth_max) |_| {
        if (emitter.wraps_owed == core.wrap_depth_max) break;

        const end, const kind = run_operand_head(emitter, position) orelse break;

        try wrap_opened(emitter, position, end, .argued, kind);
    }
}

fn wraps_run(emitter: *const Emitter, position: u32) ?struct { u32, core.Wrap, u8 } {
    assert(position < emitter.count);
    assert(emitter.wraps_owed < core.wrap_depth_max);

    if (wraps_found(emitter, position)) |found| return .{ found[0], found[1], core.nest_none };
    if (run_operand_wrap(emitter, position)) |found| return .{ found[0], .argued, found[1] };
    if (clause_wrap(emitter, position)) |found| return .{ found[0], .argued, found[1] };

    const found = wraps_settled(emitter, position) orelse return null;
    return .{ found[0], found[1], core.nest_none };
}

fn wraps_found(emitter: *const Emitter, position: u32) ?struct { u32, core.Wrap } {
    assert(position < emitter.count);
    assert(emitter.wraps_owed < core.wrap_depth_max);

    if (jsx.wrapped(emitter, position)) |found| return found;
    if (span.wrapping(emitter, position)) |close| return .{ close, .parens };
    if (cast_wrapped(emitter, position)) |close| return .{ close, .parens };
    if (call.arrow_wrapped(emitter, position)) |found| return found;
    if (own.assign_wrap(emitter, position)) |found| return found;
    if (own.value_wrap(emitter, position)) |found| return found;
    return span.operand_wrap(emitter, position);
}

fn wraps_settled(emitter: *const Emitter, position: u32) ?struct { u32, core.Wrap } {
    assert(position < emitter.count);
    assert(emitter.wraps_owed < core.wrap_depth_max);

    if (span.statement_wrap(emitter, position)) |found| return found;
    if (jsx.run_wrap(emitter, position)) |found| return found;
    if (enum_wrap(emitter, position)) |found| return found;
    if (case_wrap(emitter, position)) |found| return found;
    return iterate_wrap(emitter, position);
}

fn wrap_opened(
    emitter: *Emitter,
    position: u32,
    close: u32,
    wrap: core.Wrap,
    nest: u8,
) error{Overflow}!void {
    assert(position < emitter.count);
    assert(emitter.wraps_owed < core.wrap_depth_max);
    assert(close < emitter.count);
    assert(nest <= core.nest_bare);
    if (nest == core.nest_flat) assert(wrap == .paired);

    const floored: struct { u32, u32 } = if (nest == core.nest_none)
        wrap_floor(emitter, position, close, wrap)
    else
        .{ call.binary_floor(emitter, position, close), 0 };

    const opens: u32 = if (walk.is_open(emitter.tokens[position].kind)) 1 else 0;
    const owed = emitter.wraps_owed;

    emitter.wrapped[owed] = .{
        .close = close,
        .wrap = wrap,
        .depth = emitter.depth - opens,
        .floor = floored[0],
        .start = position,
    };

    emitter.wraps_assigned[owed] = false;
    emitter.wraps_severed[owed] = false;
    emitter.wraps_armed[owed] = wrap != .argued;
    emitter.wraps_nested[owed] = nest;
    emitter.wraps_indent[owed] = emitter.indent;
    emitter.wraps_heavy[owed] = floored[1];
    emitter.wraps_width[owed] = wrap_width(emitter, position, close, wrap);
    emitter.wraps_owed += 1;

    if (nest == core.nest_right) return;

    if (wrap == .paired) {
        if (nest != core.nest_flat) try emitter.document.push(.group_open);

        return;
    }

    try wrap_opened_grouped(emitter, position, wrap, floored[0]);
}

fn wrap_width(emitter: *const Emitter, position: u32, close: u32, wrap: core.Wrap) u32 {
    assert(position < emitter.count);
    assert(close < emitter.count);
    assert(emitter.wrapped[emitter.wraps_owed].wrap == wrap);

    switch (wrap) {
        .bodied, .hugged, .parens => return span.printed_columns(emitter, position, close),
        else => return 0,
    }
}

fn wrap_opened_grouped(
    emitter: *Emitter,
    position: u32,
    wrap: core.Wrap,
    floor: u32,
) error{Overflow}!void {
    assert(position < emitter.count);
    assert(emitter.wraps_owed > 0);
    assert(floor < std.math.maxInt(u32));
    assert(emitter.wrapped[emitter.wraps_owed - 1].wrap == wrap);

    if (wrap == .hugged) try hug_marked(emitter, position);

    const casted = wrap == .parens and cast_wrapped(emitter, position) != null;
    const opening = if (casted) emitter.opening else emitter.spacing;

    if (!own.chain_tailed(emitter, position, wrap)) try emitter.document.push(.group_open);

    switch (wrap) {
        .parens, .tagged => try emitter.document.push(.{ .if_broken = opening }),
        else => {},
    }

    if (wrap != .argued) try line.opens_broken(emitter);

    if (wrap == .argued) {
        if (floor != call.binary_level_max) try emitter.document.push(.group_open);

        return;
    }

    switch (wrap) {
        .parens, .tagged, .tagging, .valued => {},
        else => return wrap_opened_lined(emitter, position, wrap, floor),
    }

    if (wrap == .valued) {
        try emitter.document.push(.line);
    } else {
        try emitter.document.push(.soft_line);
    }

    switch (wrap) {
        .tagged, .tagging => return,
        else => {},
    }

    if (floor != call.binary_level_max) try emitter.document.push(.group_open);
}

fn wrap_opened_lined(
    emitter: *Emitter,
    position: u32,
    wrap: core.Wrap,
    floor: u32,
) error{Overflow}!void {
    assert(position < emitter.count);
    assert(emitter.wraps_owed > 0);
    assert(emitter.wrapped[emitter.wraps_owed - 1].wrap == wrap);

    const expanded = wrap == .bodied and
        (asserted_expanded(emitter, position) or own.callee_chain_tail(emitter, position));

    if (expanded) {
        try emitter.document.push(.hard_line);
    } else {
        try emitter.document.push(.line);
    }

    if (wrap != .bodied) return;
    if (floor == call.binary_level_max) return;

    try emitter.document.push(.group_open);
}

fn hug_marked(emitter: *Emitter, arrow: u32) error{Overflow}!void {
    assert(arrow < emitter.count);
    assert(emitter.wraps_owed > 0);

    const ahead = emit.ahead_of(emitter, arrow);
    const spaced = if (ahead) |held| tern.ternary_owns(emitter, held) else false;

    if (spaced) try emitter.document.push(.space);

    try emitter.document.push(.hugged);
}

fn asserted_expanded(emitter: *const Emitter, arrow: u32) bool {
    assert(arrow < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const angle = emit.ahead_of(emitter, arrow) orelse return false;
    if (!walk.text_is(emitter.tokens[angle].text(emitter.source), "<")) return false;
    if (emitter.roles[angle] & (brace.role_jsx | brace.role_jsx_tag) != 0) return false;

    const close = join.angle_close(emitter, angle) orelse return false;
    const curly = emit.ahead_of(emitter, close) orelse return false;
    if (emitter.tokens[curly].kind != .block_start) return false;

    const held = emit.ahead_of(emitter, curly) orelse return false;
    return body.parts_at(emitter, curly, held);
}

fn run_operand_head(emitter: *const Emitter, position: u32) ?struct { u32, u8 } {
    assert(position < emitter.count);
    assert(emitter.wraps_owed > 0);

    const wrapped = emitter.wrapped[emitter.wraps_owed - 1];

    const floor = if (wrapped.floor == call.binary_level_max)
        call.binary_floor(emitter, position, wrapped.close)
    else
        wrapped.floor;

    if (wrapped.start != position) return null;

    switch (wrapped.wrap) {
        .argued, .paired => {},
        else => return null,
    }

    if (floor == 0) return null;
    if (floor == call.binary_level_max) return null;
    if (emitter.tokens[position].kind == .comment) return null;
    return operand_run(emitter, position, wrapped.close, floor);
}

fn operand_run(emitter: *const Emitter, position: u32, close: u32, floor: u32) ?struct { u32, u8 } {
    assert(position < emitter.count);
    assert(floor < call.binary_level_max);
    assert(close < emitter.count);

    const end = operand_run_end(emitter, position, close, floor);
    if (end <= position) return null;
    if (!own.valued_binary(emitter, position, end)) return null;

    const trailed = operand_run_trailed(emitter, end);
    const plain = !trailed and operand_run_plain(emitter, position, end);
    var ranks: [binary_operator_max]struct { u32, u32 } = @splat(.{ 0, 0 });
    const ranked = span.operand_ranked(emitter, position, end, &ranks) orelse return null;

    if (!plain) return null;

    for (ranks[0..ranked]) |pair| {
        if (pair[1] <= floor) return null;
    }

    const operator = ranks[0][0];
    const logical = ranks[0][1] <= logical_level_max;

    const righted = ranked == 1 and (floor <= logical_level_max) != logical and
        !operand_side_run(emitter, position, operator, logical) and
        !operand_side_run(emitter, operator, end + 1, logical);

    return .{ end, if (righted) core.nest_right else core.nest_chain };
}

fn operand_run_end(emitter: *const Emitter, position: u32, close: u32, floor: u32) u32 {
    assert(position < emitter.count);
    assert(close < emitter.count);
    assert(floor < std.math.maxInt(u32));

    var depth: u32 = 0;
    var end = position;
    var scan = position;

    while (scan <= close) {
        if (call.spanned_body(emitter, scan)) |stop| {
            assert(stop >= scan);

            end = stop;
            scan = stop + 1;

            continue;
        }

        const kind = emitter.tokens[scan].kind;
        const opens = walk.is_open(kind) or kind == .block_start;
        const closes = walk.is_close(kind) or kind == .block_end;

        if (opens) {
            depth += 1;
        } else if (closes) {
            if (depth == 0) break;

            depth -= 1;
        } else if (depth == 0) {
            if (scan > position) {
                if (call.binary_floored(emitter, scan, floor)) break;
            }
        } else {}

        end = scan;
        scan += 1;
    }

    return end;
}

fn operand_run_trailed(emitter: *const Emitter, end: u32) bool {
    assert(end < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const ahead = emit.ahead_of(emitter, end) orelse return false;

    const held = if (emitter.tokens[ahead].kind == .comment)
        ahead
    else
        emit.ahead_of(emitter, ahead) orelse return false;

    if (emitter.tokens[held].kind != .comment) return false;

    const before = emit.back_of(emitter, held) orelse return true;
    return !body.parts_at(emitter, before, held);
}

fn operand_run_plain(emitter: *const Emitter, position: u32, end: u32) bool {
    assert(position <= end);
    assert(end < emitter.count);

    for (position..end + 1) |index| {
        const held: u32 = @intCast(index);

        switch (emitter.tokens[held].kind) {
            .comment => return false,
            .block_start => {
                if (body.bodied_brace(emitter, held)) return false;
                if (call.object_parted(emitter, held)) return false;
            },
            else => {},
        }
    }

    return true;
}

fn run_operand_wrap(emitter: *const Emitter, position: u32) ?struct { u32, u8 } {
    assert(position < emitter.count);
    assert(emitter.wraps_owed < core.wrap_depth_max);

    if (!emitter.policy.binary_lines) return null;

    if (emitter.wraps_owed == 0) {
        const end = rebalanced(emitter, position) orelse return null;
        return .{ end, core.nest_chain };
    }

    const wrapped = emitter.wrapped[emitter.wraps_owed - 1];

    const seat = switch (wrapped.wrap) {
        .parens, .valued, .bodied => true,
        else => false,
    };

    const reseated = wrapped.floor == call.binary_level_max and seat;

    const floor = if (reseated)
        call.binary_floor(
            emitter,
            emit.ahead_of(emitter, wrapped.start) orelse return null,
            wrapped.close,
        )
    else
        wrapped.floor;

    if (!run_operand_opens(emitter, position, wrapped, floor)) return null;

    var previous = emit.back_of(emitter, position) orelse return null;

    for (0..emitter.count) |_| {
        if (emitter.tokens[previous].kind != .comment) break;

        previous = emit.back_of(emitter, previous) orelse return null;
    }

    const opens = call.binary_floored(emitter, previous, floor) or
        (previous == wrapped.start and seat);

    if (!opens) return null;
    if (rebalanced(emitter, position)) |end| return .{ end, core.nest_chain };
    return operand_run(emitter, position, wrapped.close, floor);
}

fn run_operand_opens(
    emitter: *const Emitter,
    position: u32,
    wrapped: core.Wrapped,
    floor: u32,
) bool {
    assert(position < emitter.count);
    assert(emitter.wraps_owed > 0);
    assert(wrapped.start < emitter.count);

    const opens: u32 = if (walk.is_open(emitter.tokens[position].kind)) 1 else 0;

    switch (wrapped.wrap) {
        .argued, .paired, .parens, .valued, .bodied => {},
        else => return false,
    }

    if (floor == 0) return false;
    if (floor == call.binary_level_max) return false;
    if (wrapped.depth != emitter.depth - opens) return false;
    if (position <= wrapped.start) return false;
    if (position >= wrapped.close) return false;
    return emitter.tokens[position].kind != .comment;
}

fn rebalanced(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.rebalances.len <= std.math.maxInt(u32));

    for (0..@divFloor(emitter.rebalances.len, 2)) |pair| {
        if (emitter.rebalances[pair * 2] == position) {
            const returned = emit.back_of(emitter, emitter.rebalances[pair * 2 + 1]);

            if (returned) |mark| assert(mark < std.math.maxInt(u32));

            return returned;
        }
    }

    return null;
}

pub fn cast_wrapped(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);

    const text = emitter.tokens[position].text(emitter.source);
    if (!walk.text_is(text, ">")) return null;

    const open = cast_open(emitter, position) orelse return null;
    const head = emit.ahead_of(emitter, position) orelse return null;
    const kind = emitter.tokens[head].kind;

    assert(open < position);

    if (walk.is_open(kind)) {
        if (!cast_parenthesized_value(emitter, head)) return null;
    }

    if (kind == .block_start) return null;
    if (worded(cast_heads, emitter.tokens[head].text(emitter.source))) return null;

    const close = link.chain_stop(emitter, head) orelse head;
    const hard = cast_hard_fits(emitter, open, head, close);

    if (cast_flat_fits(emitter, open, close)) return null;
    if (cast_worded(emitter, head, close)) return null;
    if (hard) return null;
    if (!cast_paren_fits(emitter, open, position)) return null;
    return close;
}

fn cast_lead(emitter: *const Emitter, open: u32) struct { u32, u32 } {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (lead.spread(emitter, open)) |found| return found;
    if (join.line_lead(emitter, open)) |found| return found;
    return .{ emitter.line_first, emitter.printed };
}

fn cast_paren_fits(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    const from, const level = cast_lead(emitter, open);
    if (from > open) return true;

    return (level + cast_spread_levels(emitter)) * emitter.options.indent_width +
        span.printed_columns(emitter, from, close) < emitter.options.line_width;
}

fn cast_spread_levels(emitter: *const Emitter) u32 {
    assert(emitter.depth <= brace.nest_depth_max);
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    return lead.spread_levels(emitter) + lead.chain_levels(emitter);
}

pub fn cast_paren_edge(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < emitter.count);

    if (emitter.tokens[position].kind == .comment) return false;
    if (emitter.tokens[previous].kind == .comment) return false;

    if (emitter.tokens[position].is_punctuation(.paren_close)) {
        const open = emitter.brackets.open_of(position) orelse return false;

        assert(open < position);

        return cast_value_paren(emitter, open);
    }

    return cast_value_paren(emitter, previous);
}

fn cast_value_paren(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    const close = emit.back_of(emitter, open) orelse return false;
    const text = emitter.tokens[close].text(emitter.source);

    assert(close < open);

    if (!walk.text_is(text, ">")) return false;
    if (cast_open(emitter, close) == null) return false;
    return cast_paren(emitter, open);
}

pub fn cast_open(emitter: *const Emitter, close: u32) ?u32 {
    assert(close < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.angle_types) return null;
    if (!emitter.policy.return_parens) return null;

    const depth = emitter.brackets.angles_at(close);
    var scan = close;

    for (0..cast_scan_max) |_| {
        scan = emit.back_of(emitter, scan) orelse return null;

        const kind = emitter.tokens[scan].kind;
        const closes = walk.is_close(kind) or kind == .block_end;

        if (closes) {
            scan = emitter.brackets.open_of(scan) orelse return null;

            continue;
        }

        if (emitter.brackets.angles_at(scan) >= depth) continue;
        return cast_opened(emitter, scan);
    }

    return null;
}

fn cast_opened(emitter: *const Emitter, scan: u32) ?u32 {
    assert(scan < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!walk.text_is(emitter.tokens[scan].text(emitter.source), "<")) return null;
    if (emitter.roles[scan] & (brace.role_jsx | brace.role_jsx_tag) != 0) return null;

    const typed = emit.ahead_of(emitter, scan) orelse return null;
    if (emitter.roles[typed] & brace.role_type == 0) return null;

    const held = emit.back_of(emitter, scan) orelse return scan;
    if (cast_ended(emitter, held)) return null;
    if (worded(cast_heads, emitter.tokens[held].text(emitter.source))) return null;
    return scan;
}

pub fn logical_tail(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    const kind = emitter.tokens[position].kind;
    const opens = kind == .block_start or kind.eql(.{ .punctuation = .bracket_open });
    if (!opens) return false;

    const held = emit.back_of(emitter, position) orelse return false;

    assert(held < position);

    if (!worded(logical_words, emitter.tokens[held].text(emitter.source))) return false;

    const close = join.closing_of(emitter, position) orelse return false;

    assert(close > position);

    if (emit.ahead_of(emitter, position) == close) return false;

    const after = emit.ahead_of(emitter, close) orelse return true;
    const shut = emitter.tokens[after].kind;
    if (walk.is_close(shut)) return true;
    if (shut == .block_end) return true;
    return shut.eql(.{ .punctuation = .comma }) or shut.eql(.{ .punctuation = .semicolon });
}

pub fn wrapped_close(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position <= emitter.count);
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    while (emitter.wraps_owed > 0) {
        if (position <= emitter.wrapped[emitter.wraps_owed - 1].close) break;

        emitter.wraps_owed -= 1;

        try wrap_closed(emitter, position);
    }
}

fn wrap_closed(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position <= emitter.count);
    assert(emitter.wraps_owed < core.wrap_depth_max);

    const owed = emitter.wraps_owed;
    const wrapped = emitter.wrapped[owed];
    const wrap = wrapped.wrap;

    switch (wrap) {
        .membered, .paired => {},
        else => emitter.wraps_ended = position,
    }

    if (wrap == .paired) {
        if (emitter.wraps_nested[owed] != core.nest_flat) try emitter.document.push(.group_close);

        return;
    }

    if (emitter.wraps_nested[owed] == core.nest_right) {
        if (!emitter.wraps_armed[owed]) return;

        try line.closes_broken(emitter);
        try emitter.document.push(.group_close);

        return;
    }

    if (wrap == .nested) {
        try emitter.document.push(.{ .if_flat = emitter.closing });
        try ternary_dealigned(emitter, wrap);
        try line.closes_broken(emitter);
        try emitter.document.push(.@"align");

        return;
    }

    if (wrap == .parens) try line.level(emitter, emitter.wraps_indent[owed]);

    switch (wrap) {
        .argued, .parens, .valued, .bodied => {
            if (wrapped.floor != call.binary_level_max) try emitter.document.push(.group_close);
        },
        else => {},
    }

    try wrap_closed_finished(emitter, position, wrapped);
}

fn wrap_closed_finished(
    emitter: *Emitter,
    position: u32,
    wrapped: core.Wrapped,
) error{Overflow}!void {
    assert(position <= emitter.count);
    assert(emitter.wraps_owed < core.wrap_depth_max);
    assert(wrapped.start < emitter.count);

    const wrap = wrapped.wrap;
    const stepped = close_stepped(emitter, position, wrap, wrapped.start);
    const parenthesized = wrap == .linked or wrap == .parens or wrap == .tagged;
    const softened = stepped or parenthesized;

    try ternary_dealigned(emitter, wrap);

    if (wrap != .tagging) {
        if (emitter.wraps_armed[emitter.wraps_owed]) try line.closes_broken(emitter);
    }

    if (wrap == .hugged) try emitter.document.push(.{ .hugging = hug_separator(emitter, wrapped) });
    if (softened) try emitter.document.push(.soft_line);

    if (wrap == .tagging) {
        try emitter.document.push(.dedent);
        try emitter.document.push(.hard_line);
    }

    if (parenthesized) try jsx.parens_closing(emitter, wrap, wrapped.floor);

    if (wrap == .tagging) {
        try emitter.document.push(.{ .text = .{ .source = .literal, .span = emitter.closing } });
    }

    if (!groupless(emitter, wrapped.start, wrap)) try emitter.document.push(.group_close);

    try wrap_finished(emitter, wrapped.start, wrap);
}

fn case_wrap(emitter: *const Emitter, position: u32) ?struct { u32, core.Wrap } {
    assert(position < emitter.count);
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    if (emitter.wraps_owed > 0) return null;
    if (!emitter.policy.binary_lines) return null;

    const word = emit.back_of(emitter, position) orelse return null;
    if (word != emitter.line_first) return null;
    if (!walk.text_is(emitter.tokens[word].text(emitter.source), "case")) return null;

    const colon = case_colon(emitter, position) orelse return null;
    const stop = emit.back_of(emitter, colon) orelse return null;
    var ranks: [binary_operator_max]struct { u32, u32 } = @splat(.{ 0, 0 });

    if (stop <= position) return null;

    const ranked = span.operand_ranked(emitter, position, stop, &ranks) orelse return null;
    if (ranked == 0) return null;

    const room = emitter.printed * emitter.options.indent_width +
        span.printed_columns(emitter, word, colon);

    if (room <= emitter.options.line_width) return null;
    return .{ stop, .argued };
}

fn case_colon(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.wraps_owed == 0);

    var branches: u32 = 0;
    var depth: u32 = 0;
    var scan = position;

    for (0..case_scan_max) |_| {
        const token = emitter.tokens[scan];
        const opens = walk.is_open(token.kind) or token.kind == .block_start;
        const closes = walk.is_close(token.kind) or token.kind == .block_end;
        const question = walk.text_is(token.text(emitter.source), "?");

        if (opens) {
            depth += 1;
        } else if (closes) {
            if (depth == 0) return null;

            depth -= 1;
        } else if (depth == 0) {
            if (question) {
                if (!tern.optional(emitter, scan)) branches += 1;
            } else if (token.is_punctuation(.colon)) {
                if (branches == 0) return scan;

                branches -= 1;
            } else {}
        } else {}

        scan = emit.ahead_of(emitter, scan) orelse return null;
    }

    return null;
}

fn clause_wrap(emitter: *const Emitter, position: u32) ?struct { u32, u8 } {
    assert(position < emitter.count);
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    if (!emitter.policy.binary_lines) return null;
    if (emitter.depth == 0) return null;

    for (0..emitter.wraps_owed) |held| {
        if (emitter.wrapped[held].depth >= emitter.depth) return null;
    }

    const frame = line.frame(emitter);
    const kind = emitter.tokens[position].kind;
    const operand = line.word_is(emitter, position, emitter.policy.operand_words);

    if (!frame.kind.eql(.{ .punctuation = .paren_open })) return null;
    if (kind == .comment) return null;

    if (kind == .keyword) {
        if (!operand) return null;
    }

    const before = emit.back_of(emitter, position) orelse return null;

    if (before != frame.open) {
        if (!emitter.tokens[before].is_punctuation(.semicolon)) return null;
    }

    const lead_at = emit.back_of(emitter, frame.open) orelse return null;
    if (!walk.text_is(emitter.tokens[lead_at].text(emitter.source), "for")) return null;
    if (!clause_semied(emitter, frame.open, frame.close)) return null;
    return clause_wrap_run(emitter, position, frame.close);
}

fn clause_wrap_run(emitter: *const Emitter, position: u32, close: u32) ?struct { u32, u8 } {
    assert(position < emitter.count);
    assert(close < emitter.count);

    const end = bind.clause_stop(emitter, position, close);
    const stop = emit.back_of(emitter, end) orelse return null;
    if (stop < position) return null;

    const bound = line.word_is(emitter, position, emitter.policy.binder_words);
    const sequenced = !bound and clause_sequenced(emitter, position, stop);

    const binary = !sequenced and own.valued_binary(emitter, position, stop) and
        !clause_assigns(emitter, position, stop);

    if (!sequenced) {
        if (!binary) return null;
    }

    const semied: u32 = if (end < close) 1 else 0;

    const room = (header_led(emitter) + 1) * emitter.options.indent_width +
        span.printed_columns(emitter, position, stop) + semied;

    const nest = if (sequenced) core.nest_none else core.nest_bare;
    const forced = span.spread_breaks(emitter, position, stop);
    if (forced) return .{ stop, nest };
    if (room > emitter.options.line_width) return .{ stop, nest };
    return null;
}

fn clause_semied(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    var depth: u32 = 0;
    const stop = @min(close, open + 1 + clause_scan_max);

    for (open + 1..stop) |index| {
        const kind = emitter.tokens[index].kind;
        const opens = walk.is_open(kind) or kind == .block_start;
        const closes = walk.is_close(kind) or kind == .block_end;

        if (opens) {
            depth += 1;
        } else if (closes) {
            depth -|= 1;
        } else if (depth == 0) {
            if (kind.eql(.{ .punctuation = .semicolon })) return true;
        } else {}
    }

    return false;
}

fn clause_assigns(emitter: *const Emitter, head: u32, stop: u32) bool {
    assert(head <= stop);
    assert(stop < emitter.count);

    var depth: u32 = 0;
    var scan = head;

    while (scan <= stop) : (scan += 1) {
        const kind = emitter.tokens[scan].kind;
        const opens = walk.is_open(kind) or kind == .block_start;
        const closes = walk.is_close(kind) or kind == .block_end;

        if (opens) {
            depth += 1;
        } else if (closes) {
            depth -|= 1;
        } else if (depth == 0) {
            if (own.assign_operator(emitter, scan)) return true;
        } else {}
    }

    return false;
}

fn iterate_wrap(emitter: *const Emitter, position: u32) ?struct { u32, core.Wrap } {
    assert(position < emitter.count);
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    if (emitter.wraps_owed > 0) return null;
    if (!emitter.policy.binary_lines) return null;
    if (emitter.depth == 0) return null;

    const kind = emitter.tokens[position].kind;

    if (walk.is_open(kind)) {
        if (emitter.depth < 2) return null;
    }

    const frame = if (walk.is_open(kind)) emitter.nest[emitter.depth - 2] else line.frame(emitter);
    const word = emit.back_of(emitter, position) orelse return null;
    const text = emitter.tokens[word].text(emitter.source);
    const worded_in = walk.text_is(text, "of") or walk.text_is(text, "in");

    if (!frame.kind.eql(.{ .punctuation = .paren_open })) return null;
    if (kind == .comment) return null;
    if (!worded_in) return null;

    const lead_at = emit.back_of(emitter, frame.open) orelse return null;
    const headed = iterate_headed(emitter, lead_at);
    const stop = emit.back_of(emitter, frame.close) orelse return null;

    if (!headed) return null;
    if (stop < position) return null;
    if (!own.valued_binary(emitter, position, stop)) return null;

    const ahead = emit.ahead_of(emitter, frame.close);
    const braced = if (ahead) |held| emitter.tokens[held].kind == .block_start else false;
    const level = @max(link.led_level(emitter), emitter.printed);

    const room = level * emitter.options.indent_width +
        span.printed_columns(emitter, emitter.line_first, frame.close) +
        @as(u32, if (braced) 2 else 0);

    if (room <= emitter.options.line_width) return null;
    return .{ stop, .argued };
}

fn iterate_headed(emitter: *const Emitter, lead_at: u32) bool {
    assert(lead_at < emitter.count);
    assert(emitter.depth > 0);

    const text = emitter.tokens[lead_at].text(emitter.source);
    if (walk.text_is(text, "for")) return true;
    if (!walk.text_is(text, "await")) return false;

    const held = emit.back_of(emitter, lead_at) orelse return false;
    return walk.text_is(emitter.tokens[held].text(emitter.source), "for");
}

fn enum_wrap(emitter: *const Emitter, position: u32) ?struct { u32, core.Wrap } {
    assert(position < emitter.count);
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    if (emitter.wraps_owed > 0) return null;

    const seat = emit.back_of(emitter, position) orelse return null;

    assert(seat < position);

    if (!own.enum_valued(emitter, seat)) return null;

    const close = line.frame(emitter).close;
    var end = position;

    for (0..enum_scan_max) |_| {
        const held = emit.ahead_of(emitter, end) orelse return null;
        if (held >= close) break;
        if (emitter.tokens[held].is_punctuation(.comma)) break;

        end = if (walk.is_open(emitter.tokens[held].kind))
            join.closing_of(emitter, held) orelse held
        else
            held;
    }

    var ranks: [binary_operator_max]struct { u32, u32 } = @splat(.{ 0, 0 });
    const ranked = span.operand_ranked(emitter, position, end, &ranks) orelse return null;
    if (ranked == 0) return null;

    const lead_at = emit.back_of(emitter, seat) orelse return null;
    const from, const level = join.line_lead(emitter, lead_at) orelse return null;
    const ahead = emit.ahead_of(emitter, end);
    const comma: u32 = if (ahead) |held| @intFromBool(held < close) else 0;

    const room = level * emitter.options.indent_width + span.printed_columns(emitter, from, end) +
        comma;

    if (room <= emitter.options.line_width) return null;
    return .{ end, .argued };
}

fn worded(words: []const []const u8, text: []const u8) bool {
    assert(words.len > 0);
    assert(text.len <= std.math.maxInt(u32));

    for (words) |word| {
        if (walk.text_eql(word, text)) return true;
    }

    return false;
}

pub fn cast_paren(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.tokens[open].is_punctuation(.paren_open)) return false;

    const close = join.closing_of(emitter, open) orelse return false;
    if (own.arrow_typed_ahead(emitter, close) != null) return false;

    const held = emit.ahead_of(emitter, close) orelse return true;
    const token = emitter.tokens[held];
    if (token.kind == .block_start) return false;
    if (token.is_punctuation(.colon)) return false;
    return !walk.text_is(token.text(emitter.source), "=>");
}

pub fn binary_stated_joined(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < position);

    if (!emitter.policy.chain_simples) return false;
    if (!span.wrapping_operator(emitter, previous)) return false;

    const head, const stop = span.binary_run(emitter, previous) orelse return false;

    assert(head <= stop);

    if (!span.binary_stated(emitter, head)) return false;
    if (nest_bodied(emitter, previous, head, stop)) return false;

    for (head..stop + 1) |scan| {
        if (emitter.tokens[scan].kind == .comment) return false;
    }

    return !span.binary_wide(emitter, head, stop);
}

pub fn nest_bodied(emitter: *const Emitter, operator: u32, head: u32, stop: u32) bool {
    assert(operator < emitter.count);
    assert(stop < emitter.count);

    if (!span.binary_nested(emitter, operator)) return false;
    assert(head < emitter.count);

    const from = if (sole.binary_soled(emitter, head, stop)) operator else head;
    return span.spread_breaks(emitter, from, stop);
}

pub fn header_led(emitter: *const Emitter) u32 {
    assert(emitter.depth <= brace.nest_depth_max);
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    const led = @max(emitter.printed, link.led_level(emitter));

    assert(led >= emitter.printed);

    return led;
}

pub fn seat_led_level(emitter: *const Emitter) u32 {
    assert(emitter.wraps_owed > 0);
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    const open = emitter.wrapped[run_top(emitter)].start;
    return link.line_led(emitter, open) orelse link.led_level(emitter);
}

pub fn outer_runs(emitter: *const Emitter, head: u32) u32 {
    assert(head < emitter.count);
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    if (emitter.wraps_owed < 2) return 0;

    const held = line.at(emitter, head) orelse return 0;
    const opened = held.start - 1;
    const room = emitter.options.line_width -| held.level * emitter.options.indent_width;
    const top = run_top(emitter);
    var runs: u32 = 0;

    for (0..top) |at| {
        if (outer_run_broken(emitter, emitter.wrapped[at], opened, room, head)) runs += 1;
    }

    assert(runs <= top);

    return runs;
}

fn outer_run_broken(
    emitter: *const Emitter,
    wrapped: core.Wrapped,
    opened: u32,
    room: u32,
    head: u32,
) bool {
    assert(head < emitter.count);
    assert(wrapped.close < emitter.count);

    if (wrapped.wrap != .argued) return false;
    if (wrapped.start < opened) return false;
    if (span.printed_columns(emitter, wrapped.start, wrapped.close) <= room) return false;

    const operator = run_first_operator(emitter, wrapped.start, wrapped.close) orelse return false;
    return operator < head;
}

fn run_first_operator(emitter: *const Emitter, start: u32, close: u32) ?u32 {
    assert(start < emitter.count);
    assert(close < emitter.count);

    var scan = start;

    while (scan < close) {
        const kind = emitter.tokens[scan].kind;
        const opens = walk.is_open(kind) or kind == .block_start;

        if (opens) {
            scan = join.closing_of(emitter, scan) orelse return null;
        } else if (span.wrapping_operator(emitter, scan)) {
            return scan;
        } else {}

        scan += 1;
    }

    return null;
}

pub fn run_top(emitter: *const Emitter) u32 {
    assert(emitter.wraps_owed > 0);
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    var at = emitter.wraps_owed - 1;

    while (at > 0) : (at -= 1) {
        switch (emitter.wraps_nested[at]) {
            core.nest_chain, core.nest_right => {},
            else => break,
        }
    }

    assert(at < emitter.wraps_owed);

    return at;
}

pub fn statement_expanded(emitter: *const Emitter, head: u32, stop: u32) bool {
    assert(head < emitter.count);
    assert(stop < emitter.count);

    for (head..stop + 1) |index| {
        const scan: u32 = @intCast(index);
        if (emitter.tokens[scan].kind != .block_start) continue;
        if (!call.object_parted(emitter, scan)) continue;

        const shut = join.closing_of(emitter, scan) orelse continue;

        assert(shut > scan);

        if (emit.ahead_of(emitter, scan) == shut) continue;

        const before = emit.back_of(emitter, scan) orelse continue;
        if (line.word_is(emitter, before, logical_words)) continue;
        return true;
    }

    return false;
}

pub fn statement_assigns(emitter: *const Emitter, head: u32, stop: u32) bool {
    assert(head < emitter.count);
    assert(stop < emitter.count);

    var depth: u32 = 0;
    var scan = head;

    while (scan <= stop) : (scan += 1) {
        const kind = emitter.tokens[scan].kind;
        const opens = walk.is_open(kind) or kind == .block_start or bind.spans_open(emitter, scan);
        const closes = walk.is_close(kind) or kind == .block_end;

        if (opens) {
            depth += 1;
        } else if (closes) {
            depth -|= 1;
        } else if (depth == 0) {
            if (kind.eql(.{ .punctuation = .assign })) return true;
            if (own.compound_assign(emitter, scan)) return true;
        } else {}
    }

    return false;
}

pub fn rebalanced_within(emitter: *const Emitter, operator: u32) bool {
    assert(operator < emitter.count);
    assert(emitter.rebalances.len <= std.math.maxInt(u32));

    for (0..@divFloor(emitter.rebalances.len, 2)) |pair| {
        const open = emitter.rebalances[pair * 2];
        const close = emitter.rebalances[pair * 2 + 1];

        if (open < operator) {
            if (operator < close) return true;
        }
    }

    return false;
}

pub fn paired_seat(emitter: *const Emitter, operator: u32) ?u32 {
    assert(operator < emitter.count);
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    if (emitter.wraps_owed == 0) return null;

    const wrapped = emitter.wrapped[run_top(emitter)];

    const floor = if (wrapped.floor == call.binary_level_max)
        call.binary_floor(emitter, wrapped.start, wrapped.close)
    else
        wrapped.floor;

    const text = emitter.tokens[operator].text(emitter.source);

    if (wrapped.wrap != .paired) return null;
    if (wrapped.depth != emitter.depth) return null;
    if (operator <= wrapped.start) return null;
    if (operator >= wrapped.close) return null;
    if (call.binary_level(text) != floor) return null;

    const level = lead.leveled_at(emitter, wrapped.start) orelse return null;
    if (level >= emitter.printed) return null;
    return level;
}

pub fn binary_trailing(emitter: *const Emitter, operator: u32) bool {
    assert(operator < emitter.count);
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    if (emitter.wraps_owed == 0) return false;

    const wrapped = emitter.wrapped[emitter.wraps_owed - 1];
    var depth: u32 = 0;
    var scan = operator;

    for (0..clause_scan_max) |_| {
        const held = emit.back_of(emitter, scan) orelse return false;
        if (held <= wrapped.start) return false;

        const kind = emitter.tokens[held].kind;
        const closes = walk.is_close(kind) or kind == .block_end;
        const opens = walk.is_open(kind) or kind == .block_start;

        if (closes) {
            depth += 1;
        } else if (opens) {
            if (depth == 0) return false;

            depth -= 1;
        } else if (depth == 0) {
            if (binary_trailing_floored(emitter, held, wrapped.floor)) return true;
        } else {}

        scan = held;
    }

    return false;
}

fn binary_trailing_floored(emitter: *const Emitter, held: u32, floor: u32) bool {
    assert(held < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!span.wrapping_operator(emitter, held)) return false;
    return call.binary_level(emitter.tokens[held].text(emitter.source)) <= floor;
}

pub fn binary_ancestors(emitter: *const Emitter, operator: u32) u32 {
    assert(operator < emitter.count);
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    if (emitter.wraps_owed == 0) return 0;

    const wrapped = emitter.wrapped[emitter.wraps_owed - 1];
    var rank = call.binary_level(emitter.tokens[operator].text(emitter.source));
    var ancestors: u32 = 0;
    var depth: u32 = 0;
    var scan = operator;

    for (0..clause_scan_max) |_| {
        const held = emit.back_of(emitter, scan) orelse break;
        if (held <= wrapped.start) break;

        const kind = emitter.tokens[held].kind;
        const closes = walk.is_close(kind) or kind == .block_end;
        const opens = walk.is_open(kind) or kind == .block_start;

        if (closes) {
            depth += 1;
        } else if (opens) {
            if (depth == 0) break;

            depth -= 1;
        } else if (depth == 0) {
            if (span.wrapping_operator(emitter, held)) {
                const found = call.binary_level(emitter.tokens[held].text(emitter.source));
                if (found <= wrapped.floor) break;

                if (found < rank) {
                    ancestors += 1;
                    rank = found;
                }
            }
        } else {}

        scan = held;
    }

    assert(ancestors <= clause_scan_max);

    return ancestors;
}

pub fn operand_chain_level(emitter: *const Emitter, previous: u32) ?u32 {
    assert(previous < emitter.count);
    assert(emitter.line_before < emitter.count);

    if (!emit.is_dot(emitter, emitter.line_before)) return null;

    const head, _ = span.binary_run(emitter, previous) orelse return null;
    var lead_at = wide.chain_head(emitter, emitter.line_before);

    for (0..emitter.count) |_| {
        const before = emit.back_of(emitter, lead_at) orelse break;
        if (before < head) break;
        if (!worded(unary_words, emitter.tokens[before].text(emitter.source))) break;

        lead_at = before;
    }

    const rank = call.binary_level(emitter.tokens[previous].text(emitter.source));

    if (lead_at == head) {
        assert(emitter.printed -| 1 < std.math.maxInt(u32));

        return emitter.printed -| 1;
    }

    const held = emit.back_of(emitter, lead_at) orelse return null;
    if (held < head) return null;
    if (held >= previous) return null;
    if (call.binary_level(emitter.tokens[held].text(emitter.source)) != rank) return null;
    assert(emitter.printed -| 1 < std.math.maxInt(u32));

    return emitter.printed -| 1;
}

pub fn cast_grouped(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (cast_typed(emitter, open)) return true;
    if (join.cast_hugged(emitter, open)) return true;
    return cast_literal(emitter, open);
}

pub fn cast_ended(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const token = emitter.tokens[position];
    const text = token.text(emitter.source);

    switch (token.kind) {
        .identifier, .number, .string, .block_end => return true,
        else => {},
    }

    if (walk.is_close(token.kind)) return true;

    if (std.mem.endsWith(u8, text, ">")) {
        if (!walk.text_is(text, "=>")) return true;
    }

    return worded(cast_ends, text);
}

fn cast_worded(emitter: *const Emitter, head: u32, close: u32) bool {
    assert(head < emitter.count);
    assert(close < emitter.count);

    var depth: u32 = 0;
    var scan = head;

    while (scan <= close) {
        if (tmpl.spanned_unit(emitter, scan)) |end| {
            assert(end >= scan);

            scan = end + 1;

            continue;
        }

        const kind = emitter.tokens[scan].kind;
        const opens = walk.is_open(kind) or kind == .block_start;
        const closes = walk.is_close(kind) or kind == .block_end;

        if (opens) {
            depth += 1;
        } else if (closes) {
            depth -|= 1;
        } else if (depth == 0) {
            if (cast_worded_at(emitter, scan)) return true;
        } else {}

        scan += 1;
    }

    return false;
}

fn cast_worded_at(emitter: *const Emitter, scan: u32) bool {
    assert(scan < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!worded(cast_words, emitter.tokens[scan].text(emitter.source))) return false;

    const held = emit.back_of(emitter, scan) orelse return true;
    return !emit.is_dot(emitter, held);
}

fn cast_rest_closes(emitter: *const Emitter, close: u32) bool {
    assert(close < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const open = emitter.brackets.open_of(close) orelse return true;

    if (emitter.tokens[open].is_punctuation(.paren_open)) {
        if (list.calling(emitter, open)) return true;
        return split.headed(emitter, open);
    }

    const held = emit.back_of(emitter, open) orelse return true;
    return !emitter.tokens[held].ends_a_value();
}

fn cast_parenthesized_value(emitter: *const Emitter, head: u32) bool {
    assert(head < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    return cast_paren(emitter, head);
}

pub fn operand_side_run(emitter: *const Emitter, from: u32, to: u32, logical: bool) bool {
    assert(from < emitter.count);
    assert(to <= emitter.count);

    const open = if (emitter.tokens[from].is_punctuation(.paren_open))
        from
    else
        emit.ahead_of(emitter, from) orelse from;

    const close = join.closing_of(emitter, open) orelse return false;

    if (!emitter.tokens[open].is_punctuation(.paren_open)) return false;

    if (emit.ahead_of(emitter, close)) |after| {
        if (after < to) return false;
    }

    if (!own.valued_binary(emitter, open + 1, close -| 1)) return false;

    var ranks: [binary_operator_max]struct { u32, u32 } = @splat(.{ 0, 0 });
    const ranked = span.operand_ranked(emitter, open + 1, close -| 1, &ranks) orelse return false;

    for (ranks[0..ranked]) |pair| {
        if ((pair[1] <= logical_level_max) == logical) return true;
    }

    return false;
}

fn wrap_floor(
    emitter: *const Emitter,
    position: u32,
    close: u32,
    wrap: core.Wrap,
) struct { u32, u32 } {
    assert(position < emitter.count);
    assert(close < emitter.count);

    switch (wrap) {
        .argued, .paired, .parens, .valued, .bodied => {},
        else => return .{ 0, 0 },
    }

    const floored = call.binary_floor(emitter, position, close);
    const bracketed = wrap == .paired and walk.is_open(emitter.tokens[position].kind);
    const head = wrap_floor_head(emitter, position, close, bracketed);

    if (wrap == .bodied) {
        if (head) |held| {
            if (tern.ternary_owns(emitter, held)) return .{ call.binary_level_max, 0 };
        }
    }

    const sequenced = wrap_floor_sequenced(emitter, position, close, wrap);
    const bodied = if (head) |held| span.spread_breaks(emitter, held, close) else false;
    var heavy = false;

    if (!sequenced) {
        if (!bodied) {
            if (head) |held| heavy = call.binary_heavy(emitter, held, close, emitter.printed + 1);
        }
    }

    if (wrap_floor_inlined(emitter, position, close, floored)) return .{ call.binary_level_max, 0 };
    if (heavy) return .{ call.binary_level_max, floored };
    return .{ floored, 0 };
}

fn wrap_floor_head(emitter: *const Emitter, position: u32, close: u32, bracketed: bool) ?u32 {
    assert(position < emitter.count);
    assert(close < emitter.count);

    var head = if (bracketed) position else emit.ahead_of(emitter, position);

    for (0..core.wrap_depth_max) |_| {
        const held = head orelse break;
        if (emitter.tokens[held].kind != .comment) break;

        const ahead = emit.ahead_of(emitter, held) orelse null;

        head = null;

        if (ahead) |found| {
            if (found < close) head = found;
        }
    }

    return head;
}

fn wrap_floor_sequenced(emitter: *const Emitter, position: u32, close: u32, wrap: core.Wrap) bool {
    assert(position < emitter.count);
    assert(close < emitter.count);

    if (wrap != .argued) return false;
    if (emitter.depth == 0) return false;
    if (!comment.header_clauses(emitter, line.frame(emitter).open)) return false;
    return clause_sequenced(emitter, position, close);
}

fn wrap_floor_inlined(emitter: *const Emitter, position: u32, close: u32, floored: u32) bool {
    assert(position < emitter.count);
    assert(close < emitter.count);

    if (floored > logical_level_max) return false;
    if (!span.binary_inlined(emitter, close)) return false;
    return call.binary_floor_count(emitter, position, close, floored) <= 1;
}

fn clause_sequenced(emitter: *const Emitter, head: u32, stop: u32) bool {
    assert(head < emitter.count);
    assert(stop < emitter.count);

    var depth: u32 = 0;
    var scan = head;

    while (scan <= stop) {
        const spanned = call.spanned_body(emitter, scan) orelse tmpl.spanned_unit(emitter, scan);

        if (spanned) |end| {
            assert(end >= scan);

            scan = end + 1;

            continue;
        }

        const kind = emitter.tokens[scan].kind;
        const opens = walk.is_open(kind) or kind == .block_start;
        const closes = walk.is_close(kind) or kind == .block_end;

        if (opens) {
            depth += 1;
        } else if (closes) {
            depth -|= 1;
        } else if (depth == 0) {
            if (kind.eql(.{ .punctuation = .comma })) {
                if (emitter.brackets.angles_at(scan) == 0) return true;
            }
        } else {}

        scan += 1;
    }

    return false;
}

fn ternary_dealigned(emitter: *Emitter, wrap: core.Wrap) error{Overflow}!void {
    assert(emitter.wraps_owed < core.wrap_depth_max);
    assert(emitter.depth <= brace.nest_depth_max);
    assert(emitter.wrapped[emitter.wraps_owed].wrap == wrap);

    switch (wrap) {
        .guarded, .nested, .ternary => {},
        else => return,
    }

    const owed = emitter.wraps_aligned[emitter.wraps_owed];

    emitter.wraps_aligned[emitter.wraps_owed] = 0;

    for (0..owed) |_| try emitter.document.push(.dealign);
}

fn hug_separator(emitter: *const Emitter, wrapped: core.Wrapped) Span {
    assert(wrapped.wrap == .hugged);
    assert(wrapped.close < emitter.count);

    const close = emit.ahead_of(emitter, wrapped.close) orelse return emitter.comma;
    if (!emitter.tokens[close].is_punctuation(.paren_close)) return emitter.comma;

    const open = emitter.brackets.open_of(close) orelse return emitter.comma;
    const listed = list.calling(emitter, open) and !sole.cast_commented(emitter, open);
    if (listed) return emitter.comma;
    return Span{ .offset = emitter.comma.offset, .length = 0 };
}

fn close_stepped(emitter: *const Emitter, position: u32, wrap: core.Wrap, start: u32) bool {
    assert(position <= emitter.count);
    assert(start < emitter.count);
    assert(emitter.wrapped[emitter.wraps_owed].wrap == wrap);

    const ternaried = wrap == .guarded or wrap == .ternary;

    if (ternaried) {
        if (list.ternary_closed(emitter, position)) return true;
    }

    if (wrap != .bodied) return false;
    return jsx.arrow_bodied(emitter, start) != null;
}

fn wrap_finished(emitter: *Emitter, start: u32, wrap: core.Wrap) error{Overflow}!void {
    assert(start < emitter.count);
    assert(emitter.wraps_owed < core.wrap_depth_max);
    assert(emitter.wrapped[emitter.wraps_owed].wrap == wrap);

    try tern.ternary_guarded(emitter, wrap);
    try own.property_chain_closed(emitter, start, wrap);
}

fn groupless(emitter: *const Emitter, start: u32, wrap: core.Wrap) bool {
    assert(start < emitter.count);
    assert(emitter.wraps_owed < core.wrap_depth_max);

    if (wrap == .linked) return true;
    if (own.chain_tailed(emitter, start, wrap)) return true;
    if (wrap != .ternary) return false;
    return tern.ternary_paren_tested(emitter, start);
}

pub fn cast_typed(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!walk.text_is(emitter.tokens[open].text(emitter.source), "<")) return false;

    const close = join.angle_close(emitter, open) orelse return false;
    if (cast_open(emitter, close) != open) return false;

    const inner = emit.ahead_of(emitter, open) orelse return false;
    if (inner >= close) return false;

    const head = emit.ahead_of(emitter, close) orelse return false;
    const kind = emitter.tokens[head].kind;

    if (walk.is_open(kind)) {
        if (!cast_parenthesized_value(emitter, head)) return false;
    }

    if (kind == .block_start) return false;
    return !worded(cast_heads, emitter.tokens[head].text(emitter.source));
}

pub fn cast_literal(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!walk.text_is(emitter.tokens[open].text(emitter.source), "<")) return false;

    const close = join.angle_close(emitter, open) orelse return false;
    if (cast_open(emitter, close) != open) return false;

    const inner = emit.ahead_of(emitter, open) orelse return false;
    if (inner >= close) return false;

    const head = emit.ahead_of(emitter, close) orelse return false;
    const kind = emitter.tokens[head].kind;
    if (kind == .block_start) return true;
    return kind.eql(.{ .punctuation = .bracket_open });
}

fn cast_flat_fits(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < emitter.count);
    assert(close < emitter.count);

    const from, const level = cast_lead(emitter, open);
    if (from > open) return false;

    const stop = cast_rest(emitter, close);

    return (level + cast_spread_levels(emitter)) * emitter.options.indent_width +
        span.printed_columns(emitter, from, stop) <= emitter.options.line_width;
}

fn cast_rest(emitter: *const Emitter, close: u32) u32 {
    assert(close < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var tail = close;
    var scan = close;

    for (0..cast_scan_max) |_| {
        const held = emit.ahead_of(emitter, scan) orelse return tail;
        if (cast_rest_stops(emitter, held)) return tail;

        if (cast_rest_bare(emitter, held)) {
            const shut = join.closing_of(emitter, held) orelse held;

            tail = shut;
            scan = shut;

            continue;
        }

        const token = emitter.tokens[held];
        const text = token.text(emitter.source);
        const opens = walk.is_open(token.kind) or token.kind == .block_start;
        if (opens) return held;
        if (span.wrapping_operator(emitter, held)) return held;
        if (worded(cast_stops, text)) return held;

        tail = held;
        scan = held;
    }

    return tail;
}

fn cast_rest_stops(emitter: *const Emitter, held: u32) bool {
    assert(held < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const token = emitter.tokens[held];
    const text = token.text(emitter.source);

    if (token.kind == .block_end) return true;
    if (token.kind == .comment) return true;

    if (walk.text_is(text, "?")) {
        if (!tern.optional(emitter, held)) return true;
    }

    if (walk.text_is(text, ":")) return true;
    if (!walk.is_close(token.kind)) return false;
    return cast_rest_closes(emitter, held);
}

fn cast_rest_bare(emitter: *const Emitter, held: u32) bool {
    assert(held < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!walk.is_open(emitter.tokens[held].kind)) return false;

    const shut = join.closing_of(emitter, held) orelse return false;
    const inner = emit.ahead_of(emitter, held);
    if (inner == shut) return true;
    if (!walk.text_is(emitter.tokens[held].text(emitter.source), "[")) return false;

    const number = inner orelse return false;
    if (emitter.tokens[number].kind != .number) return false;
    return emit.ahead_of(emitter, number) == shut;
}

fn cast_hard_fits(emitter: *const Emitter, open: u32, head: u32, close: u32) bool {
    assert(open < head);
    assert(close < emitter.count);

    const stop = cast_hard_found(emitter, head, close) orelse return false;
    const from, const level = cast_lead(emitter, open);
    if (from > open) return false;

    return (level + cast_spread_levels(emitter)) * emitter.options.indent_width +
        span.printed_columns(emitter, from, stop) <= emitter.options.line_width;
}

fn cast_hard_found(emitter: *const Emitter, head: u32, close: u32) ?u32 {
    assert(head < emitter.count);
    assert(close < emitter.count);

    var scan = head;

    while (scan <= close) {
        if (tmpl.spanned_unit(emitter, scan)) |end| {
            assert(end >= scan);

            scan = end + 1;

            continue;
        }

        const kind = emitter.tokens[scan].kind;
        const opens = walk.is_open(kind) or kind == .block_start;

        if (opens) {
            const end = join.closing_of(emitter, scan) orelse return null;
            if (cast_hard(emitter, scan, end)) return scan;

            scan = end + 1;

            continue;
        }

        if (cast_hard(emitter, scan, scan)) return scan;

        scan += 1;
    }

    return null;
}

fn cast_hard(emitter: *const Emitter, head: u32, close: u32) bool {
    assert(head <= close);
    assert(close < emitter.count);

    var scan = head;

    while (scan <= close) {
        if (tmpl.spanned_unit(emitter, scan)) |end| {
            assert(end >= scan);

            scan = end + 1;

            continue;
        }

        const token = emitter.tokens[scan];

        if (token.kind == .block_start) {
            if (emit.bodied(emitter, scan)) return true;
            if (call.object_parted(emitter, scan)) return true;
        }

        if (token.kind == .comment) {
            if (std.mem.startsWith(u8, token.text(emitter.source), "//")) return true;
        }

        scan += 1;
    }

    return false;
}
