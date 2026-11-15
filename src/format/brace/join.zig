const std = @import("std");
const assert = std.debug.assert;
const Buffer = @import("../../stdx/bounded/buffer.zig");
const Token = @import("../../syntax/token.zig");
const bind = @import("bind.zig");
const body = @import("body.zig");
const brace = @import("../brace.zig");
const call = @import("call.zig");
const core = @import("emitter.zig");
const edge = @import("edge.zig");
const emit = @import("emit.zig");
const header = @import("header.zig");
const heritage = @import("heritage.zig");
const imports = @import("imports.zig");
const ir = @import("../ir.zig");
const lead = @import("lead.zig");
const line = @import("line.zig");
const list = @import("list.zig");
const own = @import("own.zig");
const spaced = @import("../text.zig").spaced;
const span = @import("span.zig");
const split = @import("split.zig");
const stream = @import("../stream.zig");
const tern = @import("tern.zig");
const tmpl = @import("tmpl.zig");
const unite = @import("unite.zig");
const walk = @import("../walk.zig");
const wide = @import("wide.zig");
const wrap = @import("wrap.zig");
const Emitter = core.Emitter;

const AngleMembers = struct {
    start: u32,
    stop: u32,
    count: u32,
    voids: u32,
};

const Capped = enum {
    passed,
    refused,
    skipped,
};

const cast_class_leads_max: u32 = 2;

const MixedFill = struct {
    position: u32,
    previous: u32,
    open: u32,
    close: u32,
    index: u32,
    items: u32,
};

const OperandStop = enum {
    refused,
    stopped,
    walked,
};

pub const Frame = union(enum) {
    end: End,
    flattened: Flattened,
    flattens: Flattens,
    lambdas: Lambdas,
    listing: wide.Listing,
    parted: Parted,
    probe: wide.Probe,
    run: Run,
    shaped: Shaped,
};

pub const Step = union(enum) {
    call: Frame,
    done: bool,
    found: ?u32,
};

const Answer = union(enum) {
    point: ?u32,
    verdict: bool,
};

const End = struct {
    close: u32,
    scan: u32,
    held: u32,
    head: u32,
    steps: u32,
    phase: EndPhase,
};

const EndPhase = enum {
    braced,
    chained,
    scan,
};

const Family = enum {
    crossing,
    flat,
    probe,
};

const Flattened = struct {
    position: u32,
    open: u32,
    phase: FlattenedPhase,
};

const FlattenedPhase = enum {
    arm,
    lambda,
    start,
};

const Flattens = struct {
    open: u32,
    head: u32,
    arrow: u32,
    first: u32,
    last: u32,
    stop: u32,
    inside: bool,
    phase: FlattensPhase,
};

const FlattensPhase = enum {
    parted,
    run,
    start,
};

const Lambdas = struct {
    open: u32,
    close: u32,
    first: u32,
    last: u32,
    held: u32,
    scan: u32,
    climbs: u32,
    level: u32,
    width: u32,
    phase: LambdasPhase,
};

const LambdasPhase = enum {
    climb,
    end,
    parted,
    run,
    start,
};

const Parted = struct {
    from: u32,
    end: u32,
    scan: u32,
    steps: u32,
    phase: PartedPhase,
};

const PartedPhase = enum {
    branched,
    listed,
    literal,
    scan,
};

const Run = struct {
    from: u32,
    to: u32,
    scan: u32,
    close: u32,
    steps: u32,
    skips: bool,
    soles: bool,
    waiting: bool,
};

const Shaped = struct {
    open: u32,
    first: u32,
    last: u32,
    phase: ShapedPhase,
};

const ShapedPhase = enum {
    parted,
    run,
    start,
};

const arm_words: []const []const u8 = &.{ "=>", "|" };
pub const define_scan_max: u32 = 512;
const lambda_room_width: u32 = 1;
const derive_walk_max: u32 = 6;

const arm_assigns: []const []const u8 = &.{
    "%=",
    "&=",
    "*=",
    "+=",
    "-=",
    "/=",
    "<<=",
    "=",
    ">>=",
    "^=",
    "|=",
};

const attribute_marks: []const []const u8 = &.{ "!", "[", "::" };
const boolean_words: []const []const u8 = &.{ "false", "true" };
const chain_marks: []const []const u8 = &.{ "::", "?", "!" };
const hug_blocks: []const []const u8 = &.{ "async", "do", "gen", "move", "try", "unsafe" };
const arm_blocks: []const []const u8 = &.{ "for", "if", "while" };
const arm_jumps: []const []const u8 = &.{ "break", "continue", "return", "yield" };
const arm_margin: u32 = 2;
const arm_pattern_room: u32 = 5;
const ascii_whitespace: []const u8 = " \t\n\x0c\r";
const assign_items: []const []const u8 = &.{ "const", "pub", "static", "type" };
const assign_margin_width: u32 = 2;
const assign_room: u32 = 0;
const assign_root_heads: []const []const u8 = &.{ "const", "let", "pub", "static", "type" };
const assign_root_margin: u32 = 1;
const assign_tries: u32 = 2;
const cast_margin: u32 = 4;
const flat_frame_max: u32 = 256;
const flat_tries: u32 = 2;
pub const frame_max: u32 = 512;

const header_blocks: []const []const u8 = &.{
    "async",
    "const",
    "do",
    "gen",
    "move",
    "try",
    "unsafe",
};

const hug_closers: []const u8 = ");],?";
const hug_nest_max: u32 = 16;

const hug_refused: []const []const u8 = &.{
    "const",
    "enum",
    "fn",
    "impl",
    "mod",
    "static",
    "struct",
    "trait",
    "type",
    "union",
};

const hug_room: u32 = 2;
const hug_tries: u32 = 3;
const item_heads: []const []const u8 = &.{ "default", "pub", "unsafe" };
const lambda_words: []const []const u8 = &.{ "async", "move", "static" };
const macro_branch_max: u32 = 128;
const macro_keywords: []const []const u8 = &.{ "Self", "crate", "false", "self", "super", "true" };
const macro_labels: []const []const u8 = &.{ "break", "continue", "extern" };
const macro_prefixes: []const []const u8 = &.{ "!", "-" };
const mixed_margin: u32 = 2;
const mixed_refused: []const []const u8 = &.{ "enum", "fn", "impl", "struct", "trait", "union" };

const operand_joins: []const []const u8 = &.{
    "!=",
    "%",
    "*",
    "+",
    "/",
    "<<",
    "<=",
    "==",
    ">=",
    ">>",
    "^",
    "|",
    "||",
};

const operand_stops: []const []const u8 = &.{
    "=>",
    "break",
    "continue",
    "else",
    "if",
    "in",
    "let",
    "loop",
    "match",
    "return",
    "while",
    "yield",
};

const signature_stops: []const []const u8 = &.{ ";", "=", "where", "=>", "|" };
const value_heads: []const []const u8 = &.{ "else", "if", "loop", "match", "unsafe" };
const whitespace_ascii: []const u8 = " \t\n\x0c\r";
const join_margin: u32 = 1;

const lambda_bar_heads: []const []const u8 = &.{
    ",",
    "=",
    ";",
    "=>",
    "move",
    "async",
    "static",
};

const lambda_blocks: []const []const u8 = &.{ "for", "if", "loop", "while" };
const lambda_braces: u32 = 4;
const soled_heads: []const []const u8 = &.{ "|", "move" };
const typed_stops: []const []const u8 = &.{ ";", "=", ",", "=>" };

const value_blocks: []const []const u8 = &.{
    "async",
    "const",
    "do",
    "gen",
    "loop",
    "move",
    "try",
    "unsafe",
};

const angle_prefix_max: u32 = 4;

const angle_prefixes: []const []const u8 = &.{
    "!",
    "-",
    "+",
    "await",
    "delete",
    "typeof",
    "void",
    "yield",
};

const angle_primitives: []const []const u8 = &.{
    "any",
    "bigint",
    "boolean",
    "never",
    "number",
    "object",
    "string",
    "symbol",
    "undefined",
    "unknown",
};

const angle_queries: []const []const u8 = &.{ "keyof", "readonly", "typeof", "unique", "infer" };
const angle_separators: []const []const u8 = &.{ ",", "|", "&" };
const angle_tail_max: u32 = 4;
const angle_voids: []const []const u8 = &.{ "null", "void" };
const qualified_name_max: u32 = 16;
const probe_depth_max: u32 = 256;
const step_max: u32 = 1 << 20;

comptime {
    assert(flat_frame_max > 8);
    assert(probe_depth_max > 8);
    assert(frame_max >= flat_frame_max + probe_depth_max);
    assert(step_max > frame_max);
    assert(assign_margin_width > 0);
}

comptime {
    assert(flat_frame_max > 8);
    assert(assign_margin_width > 0);
}

fn respread(out: *Buffer, text: []const u8, width: u32, base: u32) error{Overflow}!void {
    assert(text.len < std.math.maxInt(u32));
    assert(out.count() <= out.capacity());
    assert(width < std.math.maxInt(u32));
    assert(base < std.math.maxInt(u32));

    const least = respread_least(text, width);
    const line_count = std.mem.count(u8, text, "\n") + 1;
    var start: usize = 0;

    for (0..line_count) |line_index| {
        const stop = std.mem.findScalarPos(u8, text, start, '\n') orelse text.len;
        const held = text[start..stop];

        start = stop + 1;

        if (line_index == 0) {
            try out.push(std.mem.trimEnd(u8, held, ascii_whitespace));

            continue;
        }

        try out.push("\n");

        const trimmed = std.mem.trim(u8, held, ascii_whitespace);
        if (trimmed.len == 0) continue;

        try spaced(out, base + (stream.prefix_width(held, width) -| least));
        try out.push(trimmed);
    }

    assert(start == text.len + 1);
}

fn respread_least(text: []const u8, width: u32) u32 {
    assert(text.len < std.math.maxInt(u32));
    assert(width < std.math.maxInt(u32));

    const line_count = std.mem.count(u8, text, "\n") + 1;
    var least: u32 = std.math.maxInt(u32);
    var start: usize = 0;

    for (0..line_count) |line_index| {
        const stop = std.mem.findScalarPos(u8, text, start, '\n') orelse text.len;
        const held = text[start..stop];

        start = stop + 1;

        if (line_index == 0) continue;
        if (std.mem.trim(u8, held, ascii_whitespace).len == 0) continue;

        least = @min(least, stream.prefix_width(held, width));
    }

    assert(start == text.len + 1);

    return least;
}

pub fn assign_led(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    return emitter.tokens[position].is_punctuation(.assign);
}

pub fn assign_joined(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < emitter.count);

    if (!emitter.policy.assign_joins) return false;
    if (!emitter.tokens[previous].is_punctuation(.assign)) return false;
    if (!assign_braced(emitter)) return false;

    const head = assign_first(emitter, previous) orelse return false;
    const end = statement_end(emitter, position) orelse return false;
    if (wide.assign_strung(emitter, position, end)) return true;

    const stop = assign_stop(emitter, position, previous, end);
    const room = emitter.options.line_width -| assign_tried_room(emitter, position, end, stop);

    if (joined_width(emitter, head, stop, previous)) |width| {
        if (emitter.printed * emitter.options.indent_width + width <= room) return true;
    } else if (stop == end) {
        if (assign_flat(emitter, head, position, end, room)) return true;
    } else {}

    if (sole_chain(emitter, position, end)) |chain| {
        const inner, const closes = chain;
        if (chain_joined(emitter, head, previous, inner, closes)) return true;
    }

    return chain_joined(emitter, head, previous, position, end);
}

fn assign_flat(emitter: *const Emitter, head: u32, position: u32, end: u32, room: u32) bool {
    assert(head < position);
    assert(position <= end);

    if (!emitter.policy.call_budgets) return false;

    const width = flat_width(emitter, head, end) orelse return false;
    if (emitter.printed * emitter.options.indent_width + width > room) return false;
    return capped_spans(emitter, position, end);
}

fn assign_braced(emitter: *const Emitter) bool {
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.depth == 0) return true;

    assert(emitter.nest[emitter.depth - 1].open < emitter.count);

    return emitter.nest[emitter.depth - 1].kind == .block_start;
}

fn assign_stop(emitter: *const Emitter, position: u32, previous: u32, end: u32) u32 {
    assert(position <= end);
    assert(end < emitter.count);
    assert(previous < emitter.count);

    var opened = value_brace(emitter, position, end);

    if (opened != null) {
        if (assign_wrapped(emitter, position, previous)) opened = null;
    }

    const elsed = assign_elsed(emitter, position, end);
    var parted = parted_bracket(emitter, position, end);

    if (parted) |held| {
        if (opened) |open| {
            if (held >= open) parted = null;
        }
    }

    return parted orelse elsed orelse opened orelse end;
}

fn assign_tried_room(emitter: *const Emitter, position: u32, end: u32, stop: u32) u32 {
    assert(position <= end);
    assert(end < emitter.count);

    if (hugged_tail(emitter, position, end)) |hug| {
        const open, const tries = hug;

        if (open == stop) {
            assert(hug_room + hug_tries * tries < std.math.maxInt(u32));

            return hug_room + hug_tries * tries;
        }
    }

    if (assign_tried(emitter, position, end)) return assign_tries;
    return assign_room;
}

fn sole_chain(emitter: *const Emitter, position: u32, end: u32) ?struct { u32, u32 } {
    assert(position < emitter.count);
    assert(end < emitter.count);

    var scan = position;

    for (0..define_scan_max) |_| {
        const token = emitter.tokens[scan];
        if (token.is_punctuation(.paren_open)) break;
        if (token.is_punctuation(.bracket_open)) break;

        const named = token.kind == .identifier or token.kind == .keyword;
        const text = token.text(emitter.source);
        const pathed = walk.text_is(text, "::") or walk.text_is(text, "!");

        if (!named) {
            if (!pathed) return null;
        }

        const held = emit.ahead_of(emitter, scan) orelse return null;
        if (held >= end) return null;

        scan = held;
    }

    if (scan == position) return null;

    const close = closing_of(emitter, scan) orelse return null;
    if (emit.back_of(emitter, end) != close) return null;
    if (parted_items(emitter, scan, close) != 1) return null;

    const first = emit.ahead_of(emitter, scan) orelse return null;
    if (first >= close) return null;
    return .{ first, close };
}

fn assign_tried(emitter: *const Emitter, position: u32, end: u32) bool {
    assert(position < emitter.count);
    assert(end < emitter.count);

    const last = emit.back_of(emitter, end) orelse return false;
    if (last <= position) return false;
    if (!walk.text_is(emitter.tokens[last].text(emitter.source), "?")) return false;

    var depth: u32 = 0;
    var scan = position;

    while (scan < end) : (scan += 1) {
        const kind = emitter.tokens[scan].kind;

        if (walk.is_open(kind)) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            depth -|= 1;
        } else if (depth == 0) {
            if (dot_linked(emitter, scan)) return true;
        } else {}
    }

    return false;
}

fn dot_linked(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    if (!emit.is_dot(emitter, position)) return false;
    return !emit.ranges(emitter, position);
}

fn capped_spans(emitter: *const Emitter, from: u32, to: u32) bool {
    assert(from < emitter.count);
    assert(to < emitter.count);

    return verdict_of(evaluated(emitter, capped_frame(emitter, from, to, false, true)));
}

pub fn evaluated(emitter: *const Emitter, root: Frame) Answer {
    assert(emitter.count <= emitter.tokens.len);
    assert(emitter.depth <= brace.nest_depth_max);

    var held = root;

    switch (evaluated_step(emitter, &held, null)) {
        .call => |child| return evaluated_stacked(emitter, &held, &child),
        .done => |verdict| return .{ .verdict = verdict },
        .found => |point| return .{ .point = point },
    }
}

fn evaluated_stacked(emitter: *const Emitter, root: *const Frame, first: *const Frame) Answer {
    assert(emitter.count <= emitter.tokens.len);
    assert(step_max > 1);
    assert(!emitter.join_stack.evaluating);

    emitter.join_stack.evaluating = true;
    defer emitter.join_stack.evaluating = false;

    const stack = &emitter.join_stack.frames;
    var height: u32 = 1;

    stack[0] = root.*;

    var answer = evaluated_pushed(stack, &height, first);

    for (1..step_max) |_| {
        assert(height > 0);
        assert(height <= frame_max);

        switch (evaluated_step(emitter, &stack[height - 1], answer)) {
            .call => |child| answer = evaluated_pushed(stack, &height, &child),
            .done => |verdict| {
                height -= 1;
                answer = .{ .verdict = verdict };

                if (height == 0) return .{ .verdict = verdict };
            },
            .found => |point| {
                height -= 1;
                answer = .{ .point = point };

                if (height == 0) return .{ .point = point };
            },
        }
    }

    return evaluated_refusal(root);
}

fn evaluated_pushed(stack: *[frame_max]Frame, height: *u32, child: *const Frame) ?Answer {
    assert(height.* > 0);
    assert(height.* <= frame_max);

    if (evaluated_refused(stack[0..height.*], child)) return evaluated_refusal(child);

    stack[height.*] = child.*;
    height.* += 1;

    return null;
}

fn evaluated_step(emitter: *const Emitter, frame: *Frame, answer: ?Answer) Step {
    assert(emitter.count <= emitter.tokens.len);
    assert(emitter.count > 0);
    if (answer) |held| assert(held == .verdict or (held.point orelse 0) <= emitter.count);

    const step: Step = switch (frame.*) {
        .end => |*held| end_step(emitter, held, answer),
        .flattened => |*held| flattened_step(emitter, held, verdict_of(answer)),
        .flattens => |*held| flattens_step(emitter, held, answer),
        .lambdas => |*held| lambdas_step(emitter, held, answer),
        .listing => |*held| wide.listing_step(emitter, held, answered(answer)),
        .parted => |*held| parted_step(emitter, held, answer),
        .probe => |*held| wide.probe_step(emitter, held, answered(answer)),
        .run => |*held| capped_run(emitter, held, verdict_of(answer)),
        .shaped => |*held| shaped_step(emitter, held, answer),
    };

    if (step == .call) {
        if (frame.* == .run) assert(step.call == .flattened);
        if (frame.* == .flattened) assert(step.call != .run);
        if (frame.* == .listing) assert(step.call == .probe);
    }

    return step;
}

fn evaluated_refused(stack: []const Frame, child: *const Frame) bool {
    assert(stack.len > 0);
    assert(stack.len <= frame_max);

    if (stack.len == frame_max) return true;

    const family = family_of(child);
    const height = segment_height(stack, family);

    switch (family) {
        .crossing => return false,
        .flat => return height == flat_frame_max,
        .probe => {
            if (height == probe_depth_max) return true;
            return probe_cycled(stack[stack.len - height ..], &child.probe);
        },
    }
}

fn evaluated_refusal(frame: *const Frame) Answer {
    const family = family_of(frame);
    const answer: Answer = if (family == .crossing) .{ .point = null } else .{ .verdict = false };

    if (family == .crossing) assert(answer == .point);
    if (family != .crossing) assert(answer == .verdict);

    return answer;
}

fn family_of(frame: *const Frame) Family {
    const family: Family = switch (frame.*) {
        .end, .listing, .parted => .crossing,
        .flattened, .flattens, .lambdas, .run, .shaped => .flat,
        .probe => .probe,
    };

    if (family == .probe) assert(frame.* == .probe);

    return family;
}

fn segment_height(stack: []const Frame, family: Family) u32 {
    assert(stack.len > 0);
    assert(stack.len <= frame_max);

    var height: u32 = 0;

    for (0..stack.len) |index| {
        if (family_of(&stack[stack.len - 1 - index]) != family) break;

        height += 1;
    }

    assert(height <= stack.len);

    return height;
}

fn probe_cycled(segment: []const Frame, child: *const wide.Probe) bool {
    assert(segment.len <= probe_depth_max);
    assert(child.stage == 0);

    for (segment) |*held| {
        assert(held.* == .probe);

        const probe = &held.probe;
        const kinded = probe.kind == child.kind;
        const same = kinded and probe.open == child.open and probe.point == child.point;
        if (same) return true;
    }

    return false;
}

pub fn verdict_of(answer: ?Answer) bool {
    if (answer == null) return false;

    const held = answer.?;

    assert(held == .verdict);

    return held.verdict;
}

pub fn point_of(answer: ?Answer) ?u32 {
    assert(answer != null);

    const held = answer orelse return null;

    assert(held == .point);

    return held.point;
}

fn answered(answer: ?Answer) ?bool {
    if (answer == null) return null;

    const held = answer.?;

    assert(held == .verdict);

    return held.verdict;
}

fn capped_frame(emitter: *const Emitter, from: u32, to: u32, skips: bool, soles: bool) Frame {
    assert(from < emitter.count);
    assert(to < emitter.count);

    return .{ .run = .{
        .from = from,
        .to = to,
        .scan = from,
        .close = from,
        .steps = 0,
        .skips = skips,
        .soles = soles,
        .waiting = false,
    } };
}

fn capped_run(emitter: *const Emitter, run: *Run, returned: bool) Step {
    assert(run.from < emitter.count);
    assert(run.steps <= define_scan_max);

    if (run.waiting) {
        run.waiting = false;

        if (capped_resumed(emitter, run, returned)) |step| return step;

        run.steps += 1;
    }

    while (run.steps < define_scan_max) : (run.steps += 1) {
        if (capped_scan(emitter, run)) |step| return step;
    }

    return .{ .done = false };
}

fn capped_resumed(emitter: *const Emitter, run: *Run, returned: bool) ?Step {
    assert(run.scan < run.close);
    assert(emitter.tokens[run.scan].kind == .block_start);

    if (!returned) {
        switch (capped_bracket(emitter, run.scan, run.close, run.soles)) {
            .passed => {},
            .refused => return .{ .done = false },
            .skipped => {
                run.scan = run.close;

                return null;
            },
        }
    }

    run.scan = emit.ahead_of(emitter, run.scan) orelse return .{ .done = true };

    return null;
}

fn capped_scan(emitter: *const Emitter, run: *Run) ?Step {
    assert(!run.waiting);
    assert(run.scan < emitter.count);

    const scan = run.scan;
    if (scan >= run.to) return .{ .done = true };

    const kind = emitter.tokens[scan].kind;

    if (scan > run.from) {
        if (capped_link(emitter, scan)) return .{ .done = false };
    }

    if (walk.is_open(kind)) {
        const close = closing_of(emitter, scan) orelse return .{ .done = false };

        if (kind == .block_start) {
            const skipped = run.skips and lambda_bar(emitter, scan);

            if (skipped) {
                run.scan = close;

                return null;
            }

            run.close = close;
            run.waiting = true;

            return .{ .call = flattened_frame(scan) };
        }

        switch (capped_bracket(emitter, scan, close, run.soles)) {
            .passed => {},
            .refused => return .{ .done = false },
            .skipped => {
                run.scan = close;

                return null;
            },
        }
    }

    run.scan = emit.ahead_of(emitter, scan) orelse return .{ .done = true };

    return null;
}

fn capped_link(emitter: *const Emitter, scan: u32) bool {
    assert(scan < emitter.count);

    if (core.memo_found(emitter, .capped_link, scan, 0)) |answer| return answer == 1;

    const held = capped_link_scanned(emitter, scan);

    core.memo_store(emitter, .capped_link, scan, 0, @intFromBool(held));

    return held;
}

fn capped_link_scanned(emitter: *const Emitter, scan: u32) bool {
    assert(scan < emitter.count);
    assert(scan > 0);

    if (!dot_linked(emitter, scan)) return false;
    return !chained_flat(emitter, scan);
}

fn capped_bracket(emitter: *const Emitter, scan: u32, close: u32, soles: bool) Capped {
    assert(scan < close);
    assert(close < emitter.count);

    const kind = emitter.tokens[scan].kind;
    const block = kind == .block_start;

    if (block) {
        if (!wide.valued_brace(emitter, scan)) return .refused;
    }

    const cap = if (block) emitter.policy.literal_width else emitter.policy.call_width;
    const first = emit.ahead_of(emitter, scan) orelse return .skipped;
    const last = emit.back_of(emitter, close) orelse return .skipped;

    if (first >= close) return .skipped;
    if (last < first) return .skipped;

    const text = emitter.tokens[first].text(emitter.source);
    const barred = walk.text_is(text, "|") or walk.text_is(text, "move");

    const soled = !block and barred and !wide.elemental_list(emitter, scan, close) and
        wide.lambda_sole(emitter, scan, close);

    const inside = flat_width(emitter, first, last) orelse return .refused;
    const listed = !block and parted_items(emitter, scan, close) > 1;
    const kept = if (listed) wide.kept_commas(emitter, first, last) else 0;

    if (soled) return .passed;
    if (inside + kept <= cap) return .passed;
    if (block) return .refused;
    if (listed) return .refused;
    if (!soles) return .refused;
    return if (wide.sole_free(emitter, scan, close)) .passed else .refused;
}

fn chain_joined(emitter: *const Emitter, head: u32, previous: u32, position: u32, end: u32) bool {
    assert(position < emitter.count);
    assert(end < emitter.count);

    if (emitter.policy.chain_width == 0) return false;
    assert(head < emitter.count);
    assert(previous < emitter.count);

    const last, const links, _ = wide.chain_end(emitter, position);
    const after = emit.ahead_of(emitter, last);
    const blocked = if (after) |held| emitter.tokens[held].kind == .block_start else false;
    const ended = after == end or blocked;

    if (links == 0) return false;
    if (!ended) return false;

    const width = spanned_width(emitter, position, last) orelse
        (wide.chain_spread(emitter, position, last) orelse return false);

    const parent = chain_parent(emitter, position, last) orelse return false;
    const leading = joined_width(emitter, head, parent, previous) orelse return false;
    const reserved: u32 = @intFromBool(emitter.tokens[end].is_punctuation(.semicolon));
    const under = emitter.printed * emitter.options.indent_width;
    if (under + leading + reserved > emitter.options.line_width) return false;
    return chain_joined_over(emitter, position, last, links, width);
}

fn chain_joined_over(
    emitter: *const Emitter,
    position: u32,
    last: u32,
    links: u32,
    width: u32,
) bool {
    assert(links > 0);
    assert(position < emitter.count);
    assert(last < emitter.count);
    assert(width < std.math.maxInt(u32));

    const under = (emitter.printed + 1) * emitter.options.indent_width + join_margin;
    const room = emitter.options.line_width -| under;
    if (links == 1) return width > room;

    const budget = @min(room, emitter.policy.chain_width);
    const tries = wide.chain_tries(emitter, position, last);

    return width + tries > budget;
}

fn chain_parent(emitter: *const Emitter, from: u32, last: u32) ?u32 {
    assert(from < emitter.count);
    assert(last < emitter.count);

    var depth: u32 = 0;
    var held = from;
    var scan = from;

    for (0..define_scan_max) |_| {
        const kind = emitter.tokens[scan].kind;
        const linked = depth == 0 and scan > from and dot_linked(emitter, scan);
        if (linked) return held;

        if (walk.is_open(kind)) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            depth -|= 1;
        } else {}

        if (scan >= last) return null;

        held = scan;
        scan = emit.ahead_of(emitter, scan) orelse return null;
    }

    return null;
}

fn chained_flat(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    if (emitter.policy.chain_width == 0) return true;

    const head = wide.chain_head(emitter, position);
    const last, const links, _ = wide.chain_end(emitter, head);

    if (links < 2) return true;

    const width = flat_width(emitter, head, last) orelse return false;
    return width + wide.chain_tries(emitter, head, last) <= emitter.policy.chain_width;
}

pub fn arm_opened(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < emitter.count);

    const held = emit.ahead_of(emitter, previous) orelse return false;
    const kind = emitter.tokens[held].kind;

    if (kind == .block_end) {
        const open = emit.opened(emitter, held) orelse return false;
        if (lambdas(emitter, open)) return true;
        return block_flat(emitter, open);
    }

    if (kind == .block_start) {
        if (emit.ahead_of(emitter, held) == position) {
            const text = emitter.tokens[previous].text(emitter.source);
            if (!worded(arm_words, text)) return false;
            return flattened(emitter, held);
        }
    }

    if (emitter.tokens[previous].kind != .block_start) return false;
    if (emit.ahead_of(emitter, previous) != position) return false;
    return block_flat(emitter, previous);
}

pub fn arm_commas(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    if (emitter.tokens[position].kind != .block_end) return false;

    const written = wide.arm_open_written(emitter, position) orelse return false;
    if (written) return false;

    const held = emit.ahead_of(emitter, position) orelse return true;
    return !emitter.tokens[held].is_punctuation(.comma);
}

pub fn arm_dropped(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    if (!emitter.policy.arm_guards) return false;
    if (!emitter.tokens[position].is_punctuation(.comma)) return false;

    const close = emit.back_of(emitter, position) orelse return false;
    if (emitter.tokens[close].kind != .block_end) return false;

    const open = emit.opened(emitter, close) orelse return false;
    if (!arm_braced(emitter, open)) return false;
    return !flattened(emitter, close);
}

pub fn arm_tailed(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    if (!emitter.policy.arm_guards) return false;
    if (emitter.tokens[position].kind != .block_end) return false;

    const open = emit.opened(emitter, position) orelse return false;
    const last = emit.back_of(emitter, position) orelse return false;
    if (last <= open) return false;

    const kind = emitter.tokens[last].kind;
    if (kind == .comment) return false;
    if (kind.eql(.{ .punctuation = .comma })) return false;

    if (kind == .block_end) {
        if (emit.opened(emitter, last)) |opening| {
            if (arm_braced(emitter, opening)) return false;
        }
    }

    return arm_arrow(emitter, open, last);
}

fn arm_braced(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    var scan = open;

    for (0..define_scan_max) |_| {
        const held = emit.back_of(emitter, scan) orelse return false;

        assert(held < scan);

        if (emitter.tokens[held].kind != .comment) {
            return walk.text_is(emitter.tokens[held].text(emitter.source), "=>");
        }

        scan = held;
    }

    return false;
}

fn arm_arrow(emitter: *const Emitter, open: u32, last: u32) bool {
    assert(open < last);
    assert(last < emitter.count);

    var scan = last;

    for (0..define_scan_max) |_| {
        if (scan <= open) return false;

        const kind = emitter.tokens[scan].kind;
        const text = emitter.tokens[scan].text(emitter.source);

        if (walk.is_close(kind)) {
            scan = emitter.brackets.open_of(scan) orelse return false;
        } else {
            if (walk.is_open(kind)) return false;
            if (walk.text_is(text, "=>")) return true;
            if (kind.eql(.{ .punctuation = .semicolon })) return false;
        }

        scan = emit.back_of(emitter, scan) orelse return false;
    }

    return false;
}

pub fn arm_closed(emitter: *const Emitter) bool {
    assert(emitter.depth <= brace.nest_depth_max);

    const previous = emitter.previous orelse return false;
    const held = emit.ahead_of(emitter, previous) orelse return false;

    assert(held > previous);

    if (emitter.tokens[held].kind != .block_end) return false;
    return flattened(emitter, held);
}

fn angle_open(emitter: *const Emitter, head: u32, end: u32) bool {
    assert(head < emitter.count);
    assert(end < emitter.count);

    var angles: u32 = 0;
    var scan = head;

    for (0..define_scan_max) |_| {
        if (scan >= end) return angles > 0;

        const text = emitter.tokens[scan].text(emitter.source);
        const width: u32 = @intCast(text.len);

        if (opens_angle(text)) {
            angles += width;
        } else if (list.closes_angle(text)) {
            angles -|= width;
        } else {}

        scan = emit.ahead_of(emitter, scan) orelse return angles > 0;
    }

    return true;
}

fn opens_angle(text: []const u8) bool {
    assert(text.len <= std.math.maxInt(u32));

    if (text.len == 0) return false;

    for (text) |byte| {
        if (byte != '<') return false;
    }

    assert(text[0] == '<');

    return true;
}

fn dot_open(emitter: *const Emitter, from: u32, to: u32) u32 {
    assert(from < emitter.count);
    assert(to < emitter.count);

    var depth: u32 = 0;
    var links: u32 = 0;
    var scan = from;

    for (0..define_scan_max) |_| {
        if (scan >= to) return links;

        const kind = emitter.tokens[scan].kind;

        if (walk.is_open(kind)) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            depth -|= 1;
        } else if (depth == 0) {
            const text = emitter.tokens[scan].text(emitter.source);
            const linked = dot_linked(emitter, scan) or walk.text_is(text, "?");

            if (linked) links += 1;
        } else {}

        scan = emit.ahead_of(emitter, scan) orelse return links;
    }

    return links;
}

fn assign_first(emitter: *const Emitter, previous: u32) ?u32 {
    assert(previous < emitter.count);
    assert(emitter.line_first < emitter.count);

    if (emitter.line_first <= previous) return emitter.line_first;
    return edge.statement_head(emitter, previous);
}

fn block_capped(emitter: *const Emitter, open: u32, end: u32) bool {
    assert(open < end);
    assert(end < emitter.count);

    const close = emit.closing(emitter, open) orelse return false;
    if (emit.ahead_of(emitter, close) != end) return false;

    const first, const last = inner_range(emitter, open, close) orelse return false;
    if (!simple_body(emitter, first, last)) return false;
    if (!lone_item(emitter, open, close)) return false;
    return capped_spans(emitter, first, last);
}

fn inner_range(emitter: *const Emitter, open: u32, close: u32) ?struct { u32, u32 } {
    assert(open < close);
    assert(close < emitter.count);

    const first = emit.ahead_of(emitter, open) orelse return null;
    const last = emit.back_of(emitter, close) orelse return null;

    if (first >= close) return null;
    if (last <= open) return null;
    return .{ first, last };
}

fn hugged_tail(emitter: *const Emitter, position: u32, end: u32) ?struct { u32, u32 } {
    assert(position < emitter.count);
    assert(end < emitter.count);

    var scan = end;
    var tries: u32 = 0;

    for (0..define_scan_max) |stepped| {
        const held = emit.back_of(emitter, scan) orelse return null;
        if (held <= position) return null;

        const token = emitter.tokens[held];

        if (token.kind == .block_end) {
            if (stepped == 0) return null;

            const open = emitter.brackets.open_of(held) orelse return null;
            if (open <= position) return null;

            const bar = emit.back_of(emitter, open) orelse return null;
            if (!worded(soled_heads, emitter.tokens[bar].text(emitter.source))) return null;
            return .{ open, tries };
        }

        const text = token.text(emitter.source);
        if (text.len == 0) return null;
        if (std.mem.findScalar(u8, hug_closers, text[0]) == null) return null;
        if (token.length != 1) return null;

        tries += @intFromBool(walk.text_is(text, "?"));
        scan = held;
    }

    return null;
}

fn value_brace(emitter: *const Emitter, position: u32, end: u32) ?u32 {
    assert(position < emitter.count);
    assert(end < emitter.count);

    if (emitter.tokens[position].kind == .block_start) {
        if (position < end) return position;
        return null;
    }

    if (!line.word_is(emitter, position, emitter.policy.header_words)) {
        return value_word(emitter, position, end);
    }

    return value_header(emitter, position, end);
}

fn value_word(emitter: *const Emitter, position: u32, end: u32) ?u32 {
    assert(position < emitter.count);
    assert(end < emitter.count);

    if (!worded(value_blocks, emitter.tokens[position].text(emitter.source))) {
        const open, _ = hugged_tail(emitter, position, end) orelse return null;
        return open;
    }

    const held = emit.ahead_of(emitter, position) orelse return null;
    if (held >= end) return null;
    if (emitter.tokens[held].kind != .block_start) return null;
    return held;
}

fn value_header(emitter: *const Emitter, position: u32, end: u32) ?u32 {
    assert(position < emitter.count);
    assert(end < emitter.count);

    var depth: u32 = 0;
    var scan = position;

    for (0..define_scan_max) |_| {
        if (scan >= end) return null;

        const kind = emitter.tokens[scan].kind;
        const block = kind == .block_start and depth == 0;

        if (block) {
            const close = emit.closing(emitter, scan) orelse return null;
            const after = emit.ahead_of(emitter, close) orelse return null;
            const elsed = walk.text_is(emitter.tokens[after].text(emitter.source), "else");

            if (after == end) return scan;
            if (elsed) return scan;

            scan = close;

            continue;
        }

        if (walk.is_open(kind)) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            depth -|= 1;
        } else {}

        scan = emit.ahead_of(emitter, scan) orelse return null;
    }

    return null;
}

pub fn assign_headed(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < emitter.count);

    if (!emitter.policy.assign_wraps) return false;
    if (!emitter.tokens[previous].is_punctuation(.assign)) return false;
    if (emitter.brackets.angles_at(previous) > 0) return false;
    if (!assign_braced(emitter)) return false;
    if (emitter.line_first > previous) return false;

    const end = statement_end(emitter, position) orelse return false;
    if (value_brace(emitter, position, end) != null) return false;
    if (angle_open(emitter, emitter.line_first, previous)) return false;

    const spreading = assign_spread(emitter, position, end);
    const open = parted_bracket(emitter, position, end) orelse spreading orelse return false;
    if (!assign_opens(emitter, position, open)) return false;

    const fronted = wide.chain_parted_dot(emitter, position, open) orelse open;
    const front = header_width(emitter, position, fronted) orelse return false;
    const leading = header_width(emitter, emitter.line_first, previous) orelse return false;
    const under = emitter.printed * emitter.options.indent_width;
    const width = emitter.options.line_width;
    const room = width -| assign_margin(emitter);
    const seats = under + emitter.options.indent_width + front <= width;
    var calleed = false;

    if (shaped_headed(emitter, open, previous)) {
        const back = emit.back_of(emitter, open) orelse return false;
        const tail = @min(back, fronted);
        const value = header_width(emitter, position, tail) orelse return false;

        return under + leading + 1 + value > width;
    }

    if (spreading == open) {
        if (fronted == open) {
            if (callee_named(emitter, position, open)) |named| {
                calleed = under + leading + 1 + named + 1 > width;
            }
        }
    }

    if (!seats) return false;
    return leading + front > room or calleed;
}

fn assign_margin(emitter: *const Emitter) u32 {
    assert(emitter.line_first < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    if (line.word_is(emitter, emitter.line_first, assign_items)) {
        assert(assign_margin_width - 1 < std.math.maxInt(u32));

        return assign_margin_width - 1;
    }

    return assign_margin_width;
}

fn callee_named(emitter: *const Emitter, position: u32, open: u32) ?u32 {
    assert(position <= open);
    assert(open < emitter.count);

    var named: ?u32 = null;
    var scan = position;

    for (0..define_scan_max) |_| {
        if (scan >= open) break;

        const token = emitter.tokens[scan];
        const identified = token.kind == .identifier and emitter.brackets.angles_at(scan) == 0;

        if (identified) named = scan;

        scan = emit.ahead_of(emitter, scan) orelse return null;
    }

    return header_width(emitter, position, named orelse return null);
}

fn assign_spread(emitter: *const Emitter, position: u32, end: u32) ?u32 {
    assert(position < emitter.count);
    assert(end < emitter.count);

    var scan = position;

    for (0..define_scan_max) |_| {
        if (scan >= end) return null;

        if (walk.is_open(emitter.tokens[scan].kind)) {
            const close = closing_of(emitter, scan) orelse return null;
            if (body.parts_at(emitter, scan, close)) return scan;
            return null;
        }

        scan = emit.ahead_of(emitter, scan) orelse return null;
    }

    return null;
}

fn assign_elsed(emitter: *const Emitter, position: u32, end: u32) ?u32 {
    assert(position < emitter.count);
    assert(end < emitter.count);

    var depth: u32 = 0;
    var scan = position;

    for (0..define_scan_max) |_| {
        if (scan >= end) return null;

        const kind = emitter.tokens[scan].kind;

        if (walk.is_open(kind)) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            depth -|= 1;
        } else if (depth == 0) {
            const elsed = walk.text_is(emitter.tokens[scan].text(emitter.source), "else");
            if (elsed) return assign_else(emitter, scan);
        } else {}

        scan = emit.ahead_of(emitter, scan) orelse return null;
    }

    return null;
}

fn assign_else(emitter: *const Emitter, scan: u32) ?u32 {
    assert(scan < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    if (emit.back_of(emitter, scan)) |held| {
        if (emitter.tokens[held].kind == .block_end) return null;
    }

    return emit.ahead_of(emitter, scan);
}

fn assign_opens(emitter: *const Emitter, position: u32, open: u32) bool {
    assert(position < emitter.count);
    assert(open < emitter.count);

    var scan = position;

    for (0..define_scan_max) |_| {
        if (scan >= open) return scan == open;
        if (walk.is_open(emitter.tokens[scan].kind)) return false;

        scan = emit.ahead_of(emitter, scan) orelse return false;
    }

    return false;
}

pub fn assign_wrapped(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < emitter.count);

    if (!emitter.policy.assign_wraps) return false;
    if (!emitter.tokens[previous].is_punctuation(.assign)) return false;
    if (!assign_braced(emitter)) return false;

    const head = emitter.line_first;
    const end = statement_end(emitter, position) orelse return false;
    const capped = assign_capped(emitter, position, end);

    if (head > previous) return false;
    if (angle_open(emitter, head, previous)) return false;
    if (parted_bracket(emitter, position, end) != null) return false;
    if (!capped) return false;

    const whole = header_width(emitter, head, end) orelse return false;
    const width = header_width(emitter, position, end) orelse return false;
    const room = emitter.options.line_width;

    if (dot_open(emitter, position, end) > 1) return false;
    if (emitter.printed * emitter.options.indent_width + whole <= room) return false;
    return (emitter.printed + 1) * emitter.options.indent_width + width <= room;
}

fn assign_capped(emitter: *const Emitter, position: u32, end: u32) bool {
    assert(position <= end);
    assert(end < emitter.count);

    if (value_brace(emitter, position, end)) |open| return block_capped(emitter, open, end);
    return verdict_of(evaluated(emitter, capped_frame(emitter, position, end, false, true)));
}

pub fn assign_rooted(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < emitter.count);

    if (!emitter.policy.assign_wraps) return false;
    if (!emitter.tokens[previous].is_punctuation(.assign)) return false;
    if (!assign_braced(emitter)) return false;
    if (emitter.line_first > previous) return false;
    if (!line.word_is(emitter, emitter.line_first, assign_root_heads)) return false;

    const end = statement_end(emitter, position) orelse return false;
    if (chain_dots(emitter, position, end) < 2) return false;
    if (value_brace(emitter, position, end) != null) return false;

    const rooted = chain_rooted(emitter, position, end) orelse return false;
    const root = emit.back_of(emitter, rooted) orelse return false;
    if (root < position) return false;

    const front = header_width(emitter, position, root) orelse return false;
    const leading = header_width(emitter, emitter.line_first, previous) orelse return false;
    const under = emitter.printed * emitter.options.indent_width;
    const width = emitter.options.line_width;
    if (under + leading + 1 + front <= width -| assign_root_margin) return false;
    if (under + emitter.options.indent_width + front > width) return false;
    return capped_spans(emitter, position, root);
}

fn chain_dots(emitter: *const Emitter, from: u32, end: u32) u32 {
    assert(from < emitter.count);
    assert(end < emitter.count);

    var depth: u32 = 0;
    var links: u32 = 0;
    var scan = from;

    for (0..define_scan_max) |_| {
        if (scan >= end) return links;

        const kind = emitter.tokens[scan].kind;

        if (walk.is_open(kind)) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            depth -|= 1;
        } else if (depth == 0) {
            if (dot_linked(emitter, scan)) links += 1;
        } else {}

        scan = emit.ahead_of(emitter, scan) orelse return links;
    }

    return links;
}

fn chain_rooted(emitter: *const Emitter, from: u32, end: u32) ?u32 {
    assert(from < emitter.count);
    assert(end < emitter.count);

    var depth: u32 = 0;
    var scan = from;

    for (0..define_scan_max) |_| {
        if (scan >= end) return null;

        const kind = emitter.tokens[scan].kind;

        if (walk.is_open(kind)) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            depth -|= 1;
        } else if (depth == 0) {
            const rooted = dot_linked(emitter, scan) and scan > from;
            if (rooted) return scan;
        } else {}

        scan = emit.ahead_of(emitter, scan) orelse return null;
    }

    return null;
}

pub fn flattened(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    if (!emitter.policy.arm_flattens) return false;

    if (emitter.tokens[position].kind == .block_end) {
        if (wide.arm_open_written(emitter, position)) |written| return !written;
    }

    return verdict_of(evaluated(emitter, flattened_frame(position)));
}

pub fn flattened_frame(position: u32) Frame {
    assert(position < std.math.maxInt(u32));

    const frame: Frame = .{
        .flattened = .{ .position = position, .open = position, .phase = .start },
    };

    assert(frame.flattened.phase == .start);

    return frame;
}

fn flattened_step(emitter: *const Emitter, frame: *Flattened, returned: bool) Step {
    assert(frame.position < emitter.count);
    assert(frame.open < emitter.count);

    switch (frame.phase) {
        .start => {
            if (!emitter.policy.arm_flattens) return .{ .done = false };

            const kind = emitter.tokens[frame.position].kind;

            if (kind == .block_end) {
                frame.open = emit.opened(emitter, frame.position) orelse return .{ .done = false };
            } else {
                if (kind != .block_start) return .{ .done = false };
            }

            frame.phase = .arm;

            return .{ .call = .{ .flattens = flattens_frame(frame.open) } };
        },
        .arm => {
            if (returned) return .{ .done = true };

            frame.phase = .lambda;

            return .{ .call = .{ .lambdas = lambdas_frame(frame.open) } };
        },
        .lambda => return .{ .done = returned },
    }
}

fn flattens(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    return verdict_of(evaluated(emitter, .{ .flattens = flattens_frame(open) }));
}

fn flattens_frame(open: u32) Flattens {
    assert(open < std.math.maxInt(u32));

    return .{
        .open = open,
        .head = 0,
        .arrow = 0,
        .first = 0,
        .last = 0,
        .stop = 0,
        .inside = false,
        .phase = .start,
    };
}

fn flattens_step(emitter: *const Emitter, frame: *Flattens, answer: ?Answer) Step {
    assert(frame.open < emitter.count);
    assert(emitter.count <= emitter.tokens.len);
    if (frame.phase == .start) assert(answer == null);

    switch (frame.phase) {
        .start => {
            if (!flattens_arm(emitter, frame)) return .{ .done = false };

            frame.phase = .parted;

            return .{ .call = parted_frame(emitter, frame.first, frame.last) };
        },
        .parted => {
            if (!flattens_stop(emitter, frame, point_of(answer))) return .{ .done = false };

            frame.phase = .run;

            return .{ .call = capped_frame(emitter, frame.first, frame.last, false, true) };
        },
        .run => return flattens_run(emitter, frame, verdict_of(answer)),
    }
}

fn flattens_run(emitter: *const Emitter, frame: *const Flattens, returned: bool) Step {
    assert(frame.phase == .run);
    assert(frame.head < frame.arrow);

    if (frame.inside) {
        if (!returned) return .{ .done = false };
    }

    const head = frame.head;
    const seated = returned and arm_seated(emitter, head, frame.arrow, frame.first, frame.last);
    if (seated) return .{ .done = false };
    return .{ .done = arm_fits(emitter, frame.head, frame.arrow, frame.first, frame.stop) };
}

fn flattens_arm(emitter: *const Emitter, frame: *Flattens) bool {
    assert(frame.open < emitter.count);
    assert(frame.phase == .start);

    const open = frame.open;
    const arrow = emit.back_of(emitter, open) orelse return false;
    if (!walk.text_is(emitter.tokens[arrow].text(emitter.source), "=>")) return false;
    if (emit.defined_branch(emitter, open)) return false;

    const close = emit.closing(emitter, open) orelse return false;
    const first, const last = inner_range(emitter, open, close) orelse return false;
    const head = arm_head(emitter, arrow) orelse return false;
    const token = emitter.tokens[first];
    const multiline = std.mem.findScalar(u8, token.text(emitter.source), '\n') != null;
    const spilled = first == last and token.kind == .string and multiline;

    if (head >= arrow) return false;
    if (spilled) return false;
    if (line.word_is(emitter, first, arm_blocks)) return false;
    if (arm_guarded(emitter, head, arrow)) return false;
    if (arm_called(emitter, last)) return false;
    if (!simple_body(emitter, first, last)) return false;
    if (!arm_plain(emitter, first, last)) return false;

    frame.head = head;
    frame.arrow = arrow;
    frame.first = first;
    frame.last = last;

    return true;
}

fn flattens_stop(emitter: *const Emitter, frame: *Flattens, parted: ?u32) bool {
    assert(frame.first <= frame.last);
    assert(frame.head < frame.arrow);
    if (parted) |held| assert(held < emitter.count);

    const first = frame.first;
    const last = frame.last;
    const opened = arm_open(emitter, first, last);
    const branched = wide.branch_stop(emitter, parted, last);
    const both = branched != null and opened != null;
    const stop = if (both) @min(branched.?, opened.?) else branched orelse opened;
    const chained = arm_chain(emitter, first, last);
    const awaited = stop != null or chained != null;

    if (awaited) {
        if (!arm_extendable(emitter, first, last)) return false;
    }

    frame.stop = stop orelse chained orelse last;
    frame.inside = !awaited;

    if (stop) |bracket| return arm_extends(emitter, bracket, last);
    return true;
}

fn arm_extendable(emitter: *const Emitter, first: u32, last: u32) bool {
    assert(first <= last);
    assert(last < emitter.count);

    var end = last;

    for (0..define_scan_max) |_| {
        if (end <= first) break;
        if (!walk.text_is(emitter.tokens[end].text(emitter.source), "?")) break;

        end = emit.back_of(emitter, end) orelse return true;
    }

    const kind = emitter.tokens[end].kind;
    const named = kind == .identifier or kind == .keyword or kind == .number;
    if (!named) return true;
    if (end <= first) return true;

    const held = emit.back_of(emitter, end) orelse return true;
    return !emit.is_dot(emitter, held);
}

fn arm_plain(emitter: *const Emitter, first: u32, last: u32) bool {
    assert(first <= last);
    assert(last < emitter.count);

    if (line.word_is(emitter, first, arm_jumps)) return false;

    var depth: u32 = 0;
    var scan = first;

    for (0..define_scan_max) |_| {
        const kind = emitter.tokens[scan].kind;

        if (walk.is_open(kind)) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            depth -|= 1;
        } else if (depth == 0) {
            if (worded(arm_assigns, emitter.tokens[scan].text(emitter.source))) return false;
        } else {}

        if (scan >= last) return true;

        scan = emit.ahead_of(emitter, scan) orelse return true;
    }

    return true;
}

fn simple_body(emitter: *const Emitter, first: u32, last: u32) bool {
    assert(first <= last);
    assert(last < emitter.count);

    if (walk.text_is(emitter.tokens[first].text(emitter.source), "#")) return false;

    var depth: u32 = 0;
    var scan = first;

    for (0..define_scan_max) |_| {
        const kind = emitter.tokens[scan].kind;
        if (kind == .comment) return false;

        if (depth == 0) {
            if (kind.eql(.{ .punctuation = .semicolon })) return false;
        }

        if (walk.is_open(kind)) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            depth -|= 1;
        } else {}

        if (scan >= last) return true;

        scan = emit.ahead_of(emitter, scan) orelse return true;
    }

    return false;
}

fn flat_end(emitter: *const Emitter, close: u32) u32 {
    assert(close < emitter.count);

    const end = point_of(evaluated(emitter, end_frame(close))) orelse close;

    assert(end >= close);

    return end;
}

fn end_frame(close: u32) Frame {
    assert(close < std.math.maxInt(u32));

    const frame: Frame = .{ .end = .{
        .close = close,
        .scan = close,
        .held = close,
        .head = close,
        .steps = 0,
        .phase = .scan,
    } };

    assert(frame.end.phase == .scan);

    return frame;
}

fn end_step(emitter: *const Emitter, frame: *End, answer: ?Answer) Step {
    assert(frame.scan >= frame.close);
    assert(frame.steps <= define_scan_max);
    if (answer) |held| assert(held == .verdict);

    switch (frame.phase) {
        .scan => {},
        .braced => {
            if (!verdict_of(answer)) {
                const probe = wide.probe_of(.chained_over, frame.head, frame.held);

                frame.phase = .chained;

                return .{ .call = .{ .probe = probe } };
            }

            frame.scan = frame.held;
            frame.steps += 1;
        },
        .chained => {
            if (verdict_of(answer)) return .{ .found = frame.scan };

            frame.scan = frame.held;
            frame.steps += 1;
        },
    }

    frame.phase = .scan;

    return end_scan(emitter, frame);
}

fn end_scan(emitter: *const Emitter, frame: *End) Step {
    assert(frame.phase == .scan);
    assert(frame.scan < emitter.count);

    while (frame.steps < define_scan_max) : (frame.steps += 1) {
        const scan = frame.scan;
        const held = emit.ahead_of(emitter, scan) orelse return .{ .found = scan };

        assert(held > scan);

        if (body.parts_at(emitter, scan, held)) return .{ .found = scan };
        if (own.line_comment(emitter, held)) return .{ .found = scan };

        if (wide.chains_head(emitter, held)) |head| {
            frame.held = held;
            frame.head = head;
            frame.phase = .braced;

            return .{ .call = .{ .probe = wide.probe_of(.braced_line, head, 0) } };
        }

        frame.scan = held;
    }

    return .{ .found = frame.scan };
}

pub fn cast_joined(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < emitter.count);

    if (!emitter.policy.cast_joins) return false;
    if (!walk.text_is(emitter.tokens[position].text(emitter.source), "as")) return false;
    if (!walk.is_close(emitter.tokens[previous].kind)) return false;

    const head = cast_head(emitter, previous) orelse return false;
    const leading, const level = line_lead(emitter, head) orelse return false;
    const start = cast_start(emitter, head, leading, level) orelse return false;
    const reached = cast_reached(emitter, head, previous) orelse return false;
    const typed = cast_width(emitter, position) orelse return false;

    return start + reached + cast_margin + typed <= emitter.options.line_width;
}

fn cast_start(emitter: *const Emitter, head: u32, leading: u32, level: u32) ?u32 {
    assert(head < emitter.count);
    assert(leading < emitter.count);
    assert(level < std.math.maxInt(u32));

    const under = level * emitter.options.indent_width;

    if (head <= leading) {
        assert(under < std.math.maxInt(u32));

        return under;
    }

    const width = header_width(emitter, leading, head) orelse return null;
    const token = emitter.tokens[head];
    const returned = under + width - walk.columns(emitter.source, token.offset, token.end());

    assert(returned < std.math.maxInt(u32));

    return returned;
}

fn cast_reached(emitter: *const Emitter, head: u32, previous: u32) ?u32 {
    assert(head <= previous);
    assert(previous < emitter.count);

    if (emitter.line_first <= head) return header_width(emitter, head, previous);

    const width = header_width(emitter, emitter.line_first, previous) orelse return null;
    const returned = emitter.printed * emitter.options.indent_width + width;

    assert(returned < std.math.maxInt(u32));

    return returned;
}

fn cast_head(emitter: *const Emitter, previous: u32) ?u32 {
    assert(previous < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    var head = previous;
    var scan = previous;

    for (0..define_scan_max) |_| {
        if (walk.is_close(emitter.tokens[scan].kind)) {
            scan = emitter.brackets.open_of(scan) orelse return null;
            head = scan;
        }

        const found = emit.back_of(emitter, scan) orelse return null;

        assert(found < scan);

        if (cast_stopped(emitter, found)) return head;

        head = found;
        scan = found;
    }

    return null;
}

fn cast_stopped(emitter: *const Emitter, found: u32) bool {
    assert(found < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    const token = emitter.tokens[found];
    const text = token.text(emitter.source);

    if (walk.is_open(token.kind)) return true;
    if (token.is_punctuation(.colon)) return true;
    if (token.is_punctuation(.comma)) return true;
    if (token.is_punctuation(.semicolon)) return true;
    if (walk.text_is(text, "=")) return true;
    if (walk.text_is(text, "=>")) return true;
    return line.word_is(emitter, found, emitter.policy.head_stops);
}

fn cast_width(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    var end = flat_end(emitter, position);
    const token = emitter.tokens[end];
    const separated = token.is_punctuation(.comma) or token.is_punctuation(.semicolon);
    if (separated) end = emit.back_of(emitter, end) orelse return null;

    const first = emit.ahead_of(emitter, position) orelse return null;
    if (first > end) return null;
    return header_width(emitter, first, end);
}

pub fn define_joined(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (!emitter.policy.define_joins) return false;
    if (emitter.depth == 0) return false;
    if (!wide.defined(emitter, emitter.nest[emitter.depth - 1].open)) return false;
    return flat_joined(emitter, position);
}

fn define_head(emitter: *const Emitter, open: u32) ?u32 {
    assert(open < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    var depth: u32 = 0;
    var scan = open;

    for (0..define_scan_max) |_| {
        const held = emit.back_of(emitter, scan) orelse return null;
        const kind = emitter.tokens[held].kind;

        assert(held < scan);

        if (walk.is_close(kind)) {
            depth += 1;
        } else if (walk.is_open(kind)) {
            if (depth == 0) return null;

            depth -= 1;
        } else if (depth == 0) {
            if (line.word_is(emitter, held, emitter.policy.define_words)) return held;
        } else {}

        scan = held;
    }

    return null;
}

fn define_end(emitter: *const Emitter, close: u32) ?u32 {
    assert(close < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    var depth: u32 = 0;
    var scan = close;

    for (0..define_scan_max) |_| {
        scan = emit.ahead_of(emitter, scan) orelse return null;

        const kind = emitter.tokens[scan].kind;
        const stopped = kind == .block_start or kind.eql(.{ .punctuation = .semicolon });
        const clause = line.word_is(emitter, scan, emitter.policy.clause_words);

        if (depth == 0) {
            if (stopped) return scan;
            if (clause) return scan;
        }

        if (walk.is_open(kind)) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            depth -|= 1;
        } else {}
    }

    return null;
}

pub fn literal_joined(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    if (open < emitter.line_first) return false;
    if (!wide.valued_brace(emitter, open)) return false;

    const close = closing_of(emitter, open) orelse return false;
    const end = flat_end(emitter, close);
    const width = flat_width(emitter, emitter.line_first, end) orelse return false;
    const room = emitter.printed * emitter.options.indent_width + width;

    assert(close > open);

    if (room > emitter.options.line_width) return false;
    return capped_spans(emitter, emitter.line_first, close);
}

pub fn paren_joined(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < emitter.count);

    if (!emitter.policy.chain_simples) return false;

    const open = paren_joined_open(emitter, position, previous) orelse return false;
    if (list.calling(emitter, open)) return false;
    if (split.headed(emitter, open)) return false;

    const close = closing_of(emitter, open) orelse return false;
    if (list.paren_operated(emitter, open, close)) return true;
    if (paren_ternaried(emitter, open, close)) return true;
    if (paren_literal(emitter, open, close)) return true;
    return list.cast_branch_paren(emitter, open, close);
}

fn paren_joined_open(emitter: *const Emitter, position: u32, previous: u32) ?u32 {
    assert(position < emitter.count);
    assert(previous < emitter.count);

    if (emitter.tokens[previous].is_punctuation(.paren_open)) return previous;

    if (emitter.tokens[position].is_punctuation(.paren_close)) {
        return emitter.brackets.open_of(position);
    }

    return null;
}

pub fn flat_joined(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.policy.call_width == 0) return false;
    if (emitter.depth == 0) return false;

    const frame = &emitter.nest[emitter.depth - 1];
    const listed = flat_listed(emitter, frame.open, frame.kind);
    const defined = wide.defined(emitter, frame.open);

    if (!listed) return false;
    if (frame.open < emitter.line_first) return false;

    if (defined) {
        if (!emitter.policy.define_joins) return false;
    }

    const close = closing_of(emitter, frame.open) orelse return false;
    if (position > close) return false;
    if (defined) return flat_defined(emitter, frame.open, close);
    if (wide.returned_over(emitter, frame.open, close)) return false;
    if (wide.variant_held(emitter, frame.open)) return false;

    const stop = flat_end(emitter, close);
    const width = flat_width(emitter, emitter.line_first, stop) orelse return false;
    const tried: u32 = if (assign_tried(emitter, emitter.line_first, stop)) flat_tries else 0;
    const kept: u32 = @intFromBool(stop > close and flat_dropped(emitter, stop));
    const owed: u32 = @intFromBool(wide.chain_stated(emitter, close, stop));
    const under = emitter.printed * emitter.options.indent_width;
    if (under + width + tried + kept + owed > emitter.options.line_width) return false;
    return capped_spans(emitter, emitter.line_first, close);
}

fn flat_listed(emitter: *const Emitter, open: u32, kind: Token.Kind) bool {
    assert(open < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    if (kind.eql(.{ .punctuation = .paren_open })) return true;
    if (kind.eql(.{ .punctuation = .bracket_open })) return true;
    if (kind != .block_start) return false;
    return wide.valued_brace(emitter, open);
}

fn flat_defined(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    const head = define_head(emitter, open) orelse return false;
    const stop = define_end(emitter, close) orelse return false;
    const first, const level = line_lead(emitter, head) orelse return false;
    const clause = line.word_is(emitter, stop, emitter.policy.clause_words);
    const ended = if (clause) (emit.back_of(emitter, stop) orelse return false) else stop;

    if (ended > close) {
        const from = emitter.tokens[close].end();
        const to = emitter.tokens[ended].end();
        if (body.parted_by(emitter, from, to) > 0) return false;
    }

    const width = header_width(emitter, first, ended) orelse return false;
    if (level * emitter.options.indent_width + width > emitter.options.line_width) return false;
    return capped_spans(emitter, head, close);
}

fn flat_width(emitter: *const Emitter, from: u32, to: u32) ?u32 {
    assert(from < emitter.count);
    assert(to <= emitter.count);

    if (core.memo_found(emitter, .flat_width, from, to)) |answer| {
        return if (answer == core.memo_none) null else answer;
    }

    const held = flat_width_scanned(emitter, from, to);

    core.memo_store(emitter, .flat_width, from, to, held orelse core.memo_none);

    return held;
}

fn flat_width_scanned(emitter: *const Emitter, from: u32, to: u32) ?u32 {
    assert(from < emitter.count);
    assert(to < emitter.count);

    const first = emitter.tokens[from];
    var width = walk.columns(emitter.source, first.offset, first.end());
    var scan = from;

    for (0..define_scan_max) |_| {
        if (scan >= to) return width;

        const next = emit.ahead_of(emitter, scan) orelse return null;
        const token = emitter.tokens[next];
        const held = emitter.tokens[scan];
        const text = token.text(emitter.source);

        assert(next > scan);

        if (token.kind == .comment) return null;
        if (std.mem.findScalar(u8, text, '\n') != null) return null;
        if (walk.text_is(text, "#")) return null;

        if (!flat_dropped(emitter, next)) {
            const glued = wide.flat_glued(emitter, next, scan);
            const gap: u32 = @intFromBool(token.offset > held.end() and !glued);

            width += gap + walk.columns(emitter.source, token.offset, token.end());
        }

        scan = next;
    }

    return null;
}

pub fn flat_dropped(emitter: *const Emitter, next: u32) bool {
    assert(next < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    if (!emitter.tokens[next].is_punctuation(.comma)) return false;

    const found = emit.ahead_of(emitter, next) orelse return false;
    if (!walk.is_close(emitter.tokens[found].kind)) return false;

    const open = emitter.brackets.open_of(found) orelse return true;
    if (!wide.tuple_open(emitter, open)) return true;
    return wide.tuple_commas(emitter, open, found) > 1;
}

pub fn header_brace(emitter: *const Emitter, head: u32) ?u32 {
    assert(head < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    var depth: u32 = 0;
    var scan = head;

    for (0..define_scan_max) |_| {
        scan = emit.ahead_of(emitter, scan) orelse return null;

        const token = emitter.tokens[scan];
        const kind = token.kind;

        if (walk.is_close(kind)) {
            if (depth == 0) return null;

            depth -= 1;

            continue;
        }

        if (depth == 0) {
            if (kind.eql(.{ .punctuation = .semicolon })) return null;
            if (walk.text_is(token.text(emitter.source), "=>")) return null;
        }

        const nested = walk.is_open(kind) and (kind != .block_start or depth > 0);

        if (nested) {
            depth += 1;

            continue;
        }

        if (kind != .block_start) continue;

        if (!header_opened(emitter, scan)) {
            if (emit.back_of(emitter, scan) != head) return scan;
        }

        scan = emit.closing(emitter, scan) orelse return null;
        depth = 0;
    }

    return null;
}

fn header_opened(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.tokens[open].kind == .block_start);

    if (emit.back_of(emitter, open)) |found| {
        if (worded(header_blocks, emitter.tokens[found].text(emitter.source))) return true;
    }

    return wide.valued_brace(emitter, open);
}

pub fn header_head(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    var budget: u32 = define_scan_max;
    var depth: u32 = 0;
    var scan = position;

    while (budget > 0) {
        budget -= 1;

        const kind = emitter.tokens[scan].kind;

        if (depth == 0) {
            if (header_looped(emitter, scan)) return scan;
            if (kind.eql(.{ .punctuation = .comma })) return null;
            if (kind.eql(.{ .punctuation = .semicolon })) return null;
        }

        const skipped = if (walk.is_close(kind)) span.union_skipped(emitter, scan) else null;

        if (skipped) |open| {
            const steps = emitter.brackets.stepped(open, scan);
            if (steps > budget) return null;

            budget -= steps;
            scan = emit.back_of(emitter, open) orelse return null;

            continue;
        }

        if (walk.is_close(kind)) {
            depth += 1;
        } else if (walk.is_open(kind)) {
            if (depth == 0) return null;

            depth -= 1;
        } else {}

        scan = emit.back_of(emitter, scan) orelse return null;
    }

    return null;
}

fn header_looped(emitter: *const Emitter, scan: u32) bool {
    assert(scan < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    if (!line.word_is(emitter, scan, emitter.policy.header_words)) return false;
    return looping(emitter, scan);
}

pub fn angle_opened(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);
    assert(emitter.angled <= core.angle_depth_max);

    if (!emitter.policy.angle_spreads) return;
    if (emitter.angled == core.angle_depth_max) return;
    if (!walk.text_is(emitter.tokens[position].text(emitter.source), "<")) return;

    const cast = angle_opened_cast(emitter, position);

    if (!cast) {
        if (!angle_generic(emitter, position)) {
            if (!arrow_type_list(emitter, position)) return;
        }
    }

    if (tmpl.holed(emitter)) return;

    const close = angle_close(emitter, position) orelse return;
    const head = emit.ahead_of(emitter, position) orelse return;
    if (head >= close) return;
    if (cast) return cast_angle_opened(emitter, position, close, head);

    try angle_opened_listed(emitter, position, close, head);
}

fn angle_opened_cast(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.angled < core.angle_depth_max);

    if (angle_generic(emitter, position)) return false;
    if (tmpl.holed(emitter)) return false;
    if (tmpl.template_piece(emitter, position)) return false;
    return wrap.cast_grouped(emitter, position);
}

fn angle_opened_listed(
    emitter: *Emitter,
    position: u32,
    close: u32,
    head: u32,
) error{Overflow}!void {
    assert(position < head);
    assert(head < close);
    assert(emitter.angled < core.angle_depth_max);

    const returned = angle_opened_returned(emitter, position);
    const parameters = !emit.roled(emitter, position, brace.role_type);

    if (returned) return;
    if (angle_crossed(emitter, position, close)) return;

    if (!parameters) {
        if (angle_hugged(emitter, head, close)) return;
    }

    const trailed = angle_opened_trailed(emitter, close);
    const commas = !trailed and unite.angle_commas(emitter, position, close);
    const headed = angle_opened_headed(emitter, position);

    emitter.angles[emitter.angled] = .{
        .close = close,
        .depth = emitter.brackets.angles_at(head),
        .nest = emitter.depth,
        .open = position,
        .commas = commas,
        .trailed = trailed,
        .headed = headed,
    };

    emitter.angled += 1;

    if (angle_opened_hugged(emitter, position)) {
        emitter.assign_hug = false;

        try emitter.document.push(.hugs);
    }

    const element = angle_edge(emitter, parameters, position, close);

    if (headed) try emitter.document.push(.indent);

    try emitter.document.push(.group_open);
    try line.opens_broken(emitter);
    try emitter.document.push(element);
}

fn angle_opened_returned(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.angled < core.angle_depth_max);

    if (!unite.angle_returned(emitter, position)) return false;
    if (unite.union_return_breaks(emitter, position)) return false;
    if (unite.angle_return_expanded(emitter, position)) return false;
    return !angle_return_hugged(emitter, position);
}

fn angle_opened_trailed(emitter: *const Emitter, close: u32) bool {
    assert(close < emitter.count);
    assert(emitter.angled < core.angle_depth_max);

    const held = emit.back_of(emitter, close) orelse return false;

    assert(held < close);

    if (!emitter.tokens[held].is_punctuation(.comma)) return false;
    return !angle_comma_dropped(emitter, held);
}

fn angle_opened_headed(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.angled <= core.angle_depth_max);

    if (angle_headed(emitter, position)) return true;
    if (unite.intersect_angled(emitter, position)) return true;
    return interface_extended(emitter, position);
}

fn angle_opened_hugged(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.assigns <= core.assign_depth_max);

    if (!emitter.assign_hug) return false;
    if (!angle_opened_assigned(emitter, position)) return false;
    if (angle_poorly(emitter, position)) return false;

    if (emitter.typed) {
        if (angle_aliased(emitter, position)) return false;
    }

    return !angle_branched(emitter, position);
}

fn angle_opened_assigned(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.assigns <= core.assign_depth_max);

    for (emitter.assigned[0..emitter.assigns]) |assigned| {
        if (position < assigned.close) return true;
    }

    return false;
}

fn angle_edge(emitter: *const Emitter, parameters: bool, open: u32, close: u32) ir.Element {
    assert(open < close);
    assert(close < emitter.count);

    if (unite.angle_comments(emitter, open, close)) return .hard_line;
    if (!parameters) return .soft_line;
    if (cast_entry_wide(emitter, close)) return .hard_line;
    if (list.hugged_params_wide(emitter, close)) return .hard_line;
    return .soft_line;
}

fn cast_entry_wide(emitter: *const Emitter, close: u32) bool {
    assert(close < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.depth == 0) return false;

    const frame = line.frame(emitter);
    if (frame.kind != .block_start) return false;
    if (!cast_classed(emitter, frame.open)) return false;

    const params = emit.ahead_of(emitter, close) orelse return false;
    if (!emitter.tokens[params].is_punctuation(.paren_open)) return false;

    const body_open = signature_brace(emitter, params) orelse return false;

    const width = emitter.printed * emitter.options.indent_width +
        span.printed_columns(emitter, emitter.line_first, body_open);

    return width > emitter.options.line_width;
}

fn cast_classed(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    const word = cast_classed_word(emitter, open) orelse return false;
    var scan = emit.back_of(emitter, word);
    var leads: u32 = 0;

    while (leads < cast_class_leads_max) : (leads += 1) {
        const held = scan orelse break;
        const text = emitter.tokens[held].text(emitter.source);
        const leading = walk.text_is(text, "(") or walk.text_is(text, "new");
        if (!leading) break;

        scan = emit.back_of(emitter, held);
    }

    const held = scan orelse return false;
    if (!walk.text_is(emitter.tokens[held].text(emitter.source), ">")) return false;
    return wrap.cast_open(emitter, held) != null;
}

fn cast_classed_word(emitter: *const Emitter, open: u32) ?u32 {
    assert(open < emitter.count);

    const word = body.declared_word(emitter, open) orelse return null;
    if (!walk.text_is(emitter.tokens[word].text(emitter.source), "class")) return null;
    return word;
}

fn cast_angle_opened(emitter: *Emitter, position: u32, close: u32, head: u32) error{Overflow}!void {
    assert(position < emitter.count);
    assert(close < emitter.count);
    assert(head < emitter.count);
    assert(emitter.angled < core.angle_depth_max);

    emitter.angles[emitter.angled] = .{
        .close = close,
        .depth = emitter.brackets.angles_at(head),
        .nest = emitter.depth,
        .open = position,
        .commas = false,
        .trailed = false,
        .headed = false,
    };

    emitter.angled += 1;

    try emit.assigns_closed(emitter, position);
    try emitter.document.push(.group_open);
    try line.opens_broken(emitter);
    try emitter.document.push(.soft_line);
}

fn angle_branched(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.assigns <= core.assign_depth_max);

    if (emitter.assigns == 0) return false;

    const equals = emitter.assigned[emitter.assigns - 1].equals;
    var depth: u32 = 0;
    var scan = equals + 1;

    while (scan < position) {
        if (tmpl.spanned_unit(emitter, scan)) |end| {
            assert(end >= scan);

            scan = end + 1;

            continue;
        }

        const token = emitter.tokens[scan];

        if (walk.is_open(token.kind)) {
            depth += 1;
        } else if (walk.is_close(token.kind)) {
            depth -|= 1;
        } else if (depth == 0) {
            if (angle_branched_mark(emitter, token, scan)) return true;
        } else {}

        scan += 1;
    }

    return false;
}

fn angle_branched_mark(emitter: *const Emitter, token: Token, scan: u32) bool {
    assert(scan < emitter.count);
    assert(token.end() <= emitter.source.len);

    if (!walk.text_is(token.text(emitter.source), "?")) return false;
    return !tern.optional(emitter, scan);
}

fn angle_headed(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    const name = emit.back_of(emitter, open) orelse return false;
    if (emitter.tokens[name].kind != .identifier) return false;

    const keyword = emit.back_of(emitter, name) orelse return false;

    assert(keyword < name);

    if (!walk.text_is(emitter.tokens[keyword].text(emitter.source), "class")) return false;
    return heritage.both(emitter, keyword);
}

fn interface_extended(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    var name = emit.back_of(emitter, open) orelse return false;
    if (emitter.tokens[name].kind != .identifier) return false;

    for (0..qualified_name_max) |_| {
        name = interface_qualified(emitter, name) orelse break;
    }

    const extends = emit.back_of(emitter, name) orelse return false;
    if (!walk.text_is(emitter.tokens[extends].text(emitter.source), "extends")) return false;
    if (!interface_extended_named(emitter, extends)) return false;
    return emitter.line_first < extends;
}

fn interface_qualified(emitter: *const Emitter, name: u32) ?u32 {
    assert(name < emitter.count);
    assert(emitter.tokens[name].kind == .identifier);

    const dot = emit.back_of(emitter, name) orelse return null;
    if (!emit.is_dot(emitter, dot)) return null;

    const held = emit.back_of(emitter, dot) orelse return null;
    if (emitter.tokens[held].kind != .identifier) return null;
    return held;
}

fn interface_extended_named(emitter: *const Emitter, extends: u32) bool {
    assert(extends < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    const close = emit.back_of(emitter, extends) orelse return false;
    if (!walk.text_is(emitter.tokens[close].text(emitter.source), ">")) return false;

    const angle = tern.angle_opening(emitter, close) orelse return false;
    const id = emit.back_of(emitter, angle) orelse return false;
    const held = emit.back_of(emitter, id) orelse return false;

    return walk.text_is(emitter.tokens[held].text(emitter.source), "interface");
}

fn angle_aliased(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.assigns <= core.assign_depth_max);

    var held = emitter.assigns;

    while (held > 0) {
        held -= 1;

        const assigned = emitter.assigned[held];
        if (open < assigned.close) return own.alias_conditional(emitter, assigned.equals) != null;
    }

    return false;
}

fn angle_poorly(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.assigns <= core.assign_depth_max);

    const close = angle_close(emitter, open) orelse return false;
    const paren = emit.ahead_of(emitter, close) orelse return false;
    if (!emitter.tokens[paren].is_punctuation(.paren_open)) return false;

    const end = closing_of(emitter, paren) orelse return false;

    if (emit.ahead_of(emitter, paren) != end) {
        if (!list.slight_worded(emitter, paren, end)) return false;
    }

    const equals = angle_poorly_equals(emitter, open) orelse return false;
    const assigned = emit.ahead_of(emitter, equals) orelse return false;
    const first = emit.ahead_of(emitter, open) orelse return false;

    if (walk.text_is(emitter.tokens[assigned].text(emitter.source), "new")) {
        if (angle_hugged(emitter, first, close)) return true;
        return angle_worded(emitter, first, close);
    }

    const head = angle_poorly_prefixed(emitter, assigned) orelse return false;
    const stop = emit.back_of(emitter, open) orelse return false;

    if (angle_complex(emitter, first, close)) return false;
    return span.member_slight(emitter, head, stop);
}

fn angle_poorly_equals(emitter: *const Emitter, open: u32) ?u32 {
    assert(open < emitter.count);
    assert(emitter.assigns <= core.assign_depth_max);

    var held = emitter.assigns;

    while (held > 0) {
        held -= 1;

        const assigned = emitter.assigned[held];
        if (open < assigned.close) return assigned.equals;
    }

    return null;
}

fn angle_poorly_prefixed(emitter: *const Emitter, assigned: u32) ?u32 {
    assert(assigned < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    var head = assigned;

    for (0..angle_prefix_max) |_| {
        if (!worded(angle_prefixes, emitter.tokens[head].text(emitter.source))) break;

        head = emit.ahead_of(emitter, head) orelse return null;
    }

    return head;
}

fn angle_worded(emitter: *const Emitter, first: u32, close: u32) bool {
    assert(first <= close);
    assert(close < emitter.count);

    var words: u32 = 0;
    var scan = first;

    while (scan < close) : (scan += 1) {
        const token = emitter.tokens[scan];
        if (token.kind == .comment) continue;

        if (token.kind != .newline) {
            if (token.length > 0) words += 1;
        }
    }

    return words == 1;
}

pub fn angle_complex(emitter: *const Emitter, first: u32, close: u32) bool {
    assert(first <= close);
    assert(close < emitter.count);

    if (emitter.tokens[first].kind == .block_start) return true;

    var depth: u32 = 0;
    var scan = first;

    while (scan < close) : (scan += 1) {
        const token = emitter.tokens[scan];
        const text = token.text(emitter.source);
        const opens = walk.is_open(token.kind) or walk.text_is(text, "<");

        if (opens) {
            depth += 1;

            continue;
        }

        if (walk.is_close(token.kind)) {
            depth -|= 1;
        } else if (list.closes_angle(text)) {
            depth -|= @as(u32, @intCast(text.len));
        } else if (depth == 0) {
            if (worded(angle_separators, text)) return true;
        } else {}
    }

    return false;
}

pub fn angle_closed(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);
    assert(emitter.angled <= core.angle_depth_max);

    if (emitter.angled == 0) return;
    if (emitter.angles[emitter.angled - 1].close != position) return;

    const text = emitter.tokens[position].text(emitter.source);
    const deepest = emitter.brackets.angles_at(position);
    const commented = angle_closed_commented(emitter, position);

    for (0..text.len) |index| {
        try angle_closed_step(emitter, position, deepest, @intCast(index), commented);
    }

    emitter.angle_owed = 1;
    emitter.previous = position;
    emitter.resume_at = position + 1;
    emitter.suppress_space = false;
}

fn angle_closed_commented(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.angled > 0);

    const held = emit.back_of(emitter, position) orelse return false;
    const token = emitter.tokens[held];
    if (token.kind != .comment) return false;
    if (std.mem.startsWith(u8, token.text(emitter.source), "//")) return true;
    return angle_commented(emitter, position, held);
}

fn angle_closed_step(
    emitter: *Emitter,
    position: u32,
    deepest: u32,
    step: u32,
    commented: bool,
) error{Overflow}!void {
    assert(position < emitter.count);
    assert(emitter.angled <= core.angle_depth_max);
    assert(deepest < std.math.maxInt(u32));
    assert(step <= step_max);

    const angle = angle_closed_armed(emitter, position, deepest, step);

    if (angle) |armed| {
        if (armed.commas) try emitter.document.push(.{ .if_broken = emitter.comma });

        try line.closes_broken(emitter);

        const ends = armed.trailed or commented;

        if (!ends) try emitter.document.push(.soft_line);
    }

    try emitter.document.push(.{ .text = .{ .source = .literal, .span = emitter.angle } });

    const armed = angle orelse return;

    try emitter.document.push(.group_close);

    if (armed.headed) try emitter.document.push(.dedent);
}

fn angle_closed_armed(emitter: *Emitter, position: u32, deepest: u32, step: u32) ?core.Angle {
    assert(position < emitter.count);
    assert(emitter.angled <= core.angle_depth_max);

    if (emitter.angled == 0) return null;

    const angle = emitter.angles[emitter.angled - 1];
    if (angle.close != position) return null;
    if (angle.depth != deepest - step) return null;

    emitter.angled -= 1;

    return angle;
}

pub fn angle_ended(emitter: *Emitter) bool {
    assert(emitter.angle_owed <= 1);

    const owed = emitter.angle_owed;

    emitter.angle_owed = 0;

    assert(emitter.angle_owed == 0);

    return owed > 0;
}

pub fn angle_spread(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.angled <= core.angle_depth_max);

    if (emitter.angled == 0) return false;

    const angle = emitter.angles[emitter.angled - 1];
    if (position > angle.close) return false;
    if (emitter.depth != angle.nest) return false;
    return emitter.brackets.angles_at(position) >= angle.depth;
}

pub fn angle_commented(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < emitter.count);

    if (emitter.tokens[previous].kind != .comment) return false;
    if (!angle_spread(emitter, position)) return false;
    return body.parts_at(emitter, previous, position);
}

pub fn angle_comment_level(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);

    const previous = emitter.previous orelse return null;

    assert(previous < position);

    if (!angle_commented(emitter, position, previous)) return null;

    assert(emitter.angled > 0);

    const head = angle_head(emitter, position) orelse emitter.angles[emitter.angled - 1].open;
    return lead.leveled_at(emitter, head);
}

pub fn angle_lined(emitter: *const Emitter, previous: u32) bool {
    assert(previous < emitter.count);
    assert(emitter.angled <= core.angle_depth_max);

    if (emitter.angled == 0) return false;

    const angle = emitter.angles[emitter.angled - 1];

    if (!emitter.tokens[previous].is_punctuation(.comma)) return false;
    if (previous >= angle.close) return false;
    return emitter.brackets.angles_at(previous) == angle.depth;
}

pub fn angle_head(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    const depth = emitter.brackets.angles_at(position);
    if (depth == 0) return null;

    var scan = position;

    for (0..define_scan_max) |_| {
        const held = emit.back_of(emitter, scan) orelse return null;
        const kind = emitter.tokens[held].kind;

        assert(held < scan);

        if (walk.is_close(kind)) {
            scan = emitter.brackets.open_of(held) orelse return null;

            continue;
        }

        if (emitter.brackets.angles_at(held) < depth) {
            if (angle_generic(emitter, held)) return held;
            return null;
        }

        scan = held;
    }

    return null;
}

pub fn angle_generic(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    if (!walk.text_is(emitter.tokens[open].text(emitter.source), "<")) return false;

    const before = emit.back_of(emitter, open) orelse return false;
    const token = emitter.tokens[before];

    assert(before < open);

    if (angle_named(emitter, token)) {
        if (walk.text_is(token.text(emitter.source), "function")) return true;
        if (token.end() == emitter.tokens[open].offset) return true;
    }

    if (walk.text_is(token.text(emitter.source), "*")) {
        const word = emit.back_of(emitter, before) orelse return false;
        if (walk.text_is(emitter.tokens[word].text(emitter.source), "function")) return true;
    }

    return unite.angle_signed(emitter, open);
}

fn angle_named(emitter: *const Emitter, token: Token) bool {
    assert(token.end() <= emitter.source.len);
    assert(emitter.count <= emitter.tokens.len);

    const text = token.text(emitter.source);

    if (token.kind == .identifier) return true;
    if (token.kind == .keyword) return true;
    if (token.is_punctuation(.bracket_close)) return true;
    if (token.is_punctuation(.paren_close)) return true;
    if (walk.text_is(text, "::")) return true;
    return list.closes_angle(text);
}

fn arrow_type_list(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    if (!walk.text_is(emitter.tokens[open].text(emitter.source), "<")) return false;

    const close = angle_close(emitter, open) orelse return false;
    if (angle_sole_trailed(emitter, open, close)) return false;

    const paren = emit.ahead_of(emitter, close) orelse return false;
    if (!emitter.tokens[paren].is_punctuation(.paren_open)) return false;

    const shut = closing_of(emitter, paren) orelse return false;
    return own.arrow_typed_ahead(emitter, shut) != null;
}

fn angle_sole_trailed(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    const from = emitter.tokens[open].end();
    const to = emitter.tokens[close].offset;
    if (body.parted_by(emitter, from, to) > 0) return false;

    const depth = emitter.brackets.angles_at(close);
    var commas: u32 = 0;

    for (open + 1..close) |index| {
        const scan: u32 = @intCast(index);
        if (!emitter.tokens[scan].is_punctuation(.comma)) continue;

        if (emitter.brackets.angles_at(scan) == depth) commas += 1;
    }

    if (commas != 1) return false;

    const held = emit.back_of(emitter, close) orelse return false;
    return emitter.tokens[held].is_punctuation(.comma);
}

pub fn angle_close(emitter: *const Emitter, open: u32) ?u32 {
    assert(open < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    const depth = emitter.brackets.angles_at(open);
    var held = open;
    var scan = open;

    for (0..define_scan_max) |_| {
        const found = emit.ahead_of(emitter, scan) orelse return null;
        const kind = emitter.tokens[found].kind;

        assert(found > scan);

        if (tmpl.template_body(emitter, found)) |end| {
            held = end;
            scan = end;

            continue;
        }

        if (emitter.brackets.angles_at(found) <= depth) {
            if (list.closes_angle(emitter.tokens[held].text(emitter.source))) return held;
            return null;
        }

        if (walk.is_open(kind)) {
            held = emitter.brackets.close_of(found) orelse return null;
            scan = held;

            continue;
        }

        held = found;
        scan = found;
    }

    return null;
}

fn angle_stop(emitter: *const Emitter, close: u32) u32 {
    assert(close < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    var scan = close;

    for (0..define_scan_max) |_| {
        const held = emit.ahead_of(emitter, scan) orelse return scan;
        const token = emitter.tokens[held];
        if (token.kind == .comment) return scan;
        if (body.parted_by(emitter, emitter.tokens[scan].end(), token.offset) > 0) return scan;
        if (walk.text_is(token.text(emitter.source), "=")) return held;

        if (imports.import_span(emitter, held)) |end| {
            scan = end;

            continue;
        }

        if (walk.is_open(token.kind)) {
            if (!angle_empty(emitter, held)) return held;
        }

        scan = held;
    }

    return scan;
}

fn angle_empty(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(walk.is_open(emitter.tokens[open].kind));

    const close = emitter.brackets.close_of(open) orelse return false;
    return emit.ahead_of(emitter, open) == close;
}

pub fn angle_joined(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.line_first < emitter.count);

    if (emitter.brackets.angles_at(position) == 0) return false;

    const open = angle_head(emitter, position) orelse return false;
    if (open < emitter.line_first) return false;

    if (emitter.angled < core.angle_depth_max) {
        if (angle_opened_returned(emitter, open)) return true;
    }

    const close = angle_close(emitter, open) orelse return false;
    const impl = wide.impl_angled(emitter, open);
    const stop = if (impl) close else angle_stop(emitter, close);
    const flat = flat_width(emitter, emitter.line_first, stop) orelse return false;
    const width = if (impl) wide.impl_width(emitter, emitter.line_first, close) else flat;
    const reserved = wide.angle_reserved(emitter, open, stop);
    const under = emitter.printed * emitter.options.indent_width;
    if (under + width + reserved > emitter.options.line_width) return false;
    return capped_spans(emitter, emitter.line_first, close);
}

pub fn angle_tight(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < emitter.count);

    const text = emitter.tokens[position].text(emitter.source);
    const depth = emitter.brackets.angles_at(position);
    const less = walk.text_is(emitter.tokens[previous].text(emitter.source), "<");
    const opened = less and depth > emitter.brackets.angles_at(previous);
    const closed = depth > 0 and list.closes_angle(text);
    const angled = opened or closed;
    if (!angled) return false;
    if (angle_joined(emitter, position)) return true;
    return angle_owned(emitter, position);
}

fn angle_crossed(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    for (emitter.assigned[0..emitter.assigns]) |assigned| {
        const stop = assigned.close;

        if (stop > open) {
            if (stop < close) return true;
        }
    }

    for (emitter.wrapped[0..emitter.wraps_owed]) |wrapped| {
        const stop = wrapped.close;

        if (stop > open) {
            if (stop < close) return true;
        }
    }

    return false;
}

fn angle_owned(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.angled <= core.angle_depth_max);

    if (emitter.angled == 0) return false;
    return position <= emitter.angles[emitter.angled - 1].close;
}

pub fn angle_dropped(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    if (!emitter.tokens[position].is_punctuation(.comma)) return false;

    const next = emit.ahead_of(emitter, position) orelse return false;

    assert(next > position);

    if (!list.closes_angle(emitter.tokens[next].text(emitter.source))) return false;
    return angle_joined(emitter, next);
}

pub fn angle_comma_dropped(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    if (!emitter.policy.angle_calls) return false;
    if (!emitter.tokens[position].is_punctuation(.comma)) return false;

    const close = emit.ahead_of(emitter, position) orelse return false;
    if (!walk.text_is(emitter.tokens[close].text(emitter.source), ">")) return false;

    const before = list.opening(emitter, close, 1) orelse return false;
    const open = emit.ahead_of(emitter, before) orelse return false;

    if (!emitter.policy.arrow_commas) return true;
    if (!angle_comma_arrowed(emitter, before, close)) return true;
    return angle_comma_counted(emitter, open, close) > 1;
}

fn angle_comma_arrowed(emitter: *const Emitter, before: u32, close: u32) bool {
    assert(before < close);
    assert(close < emitter.count);

    if (wrap.cast_ended(emitter, before)) return false;

    const held = emit.ahead_of(emitter, close) orelse return false;
    return emitter.tokens[held].is_punctuation(.paren_open);
}

fn angle_comma_counted(emitter: *const Emitter, open: u32, close: u32) u32 {
    assert(open < close);
    assert(close < emitter.count);

    var depth: u32 = 0;
    var commas: u32 = 0;

    for (open + 1..close) |index| {
        const token = emitter.tokens[index];
        const text = token.text(emitter.source);
        const opens = walk.is_open(token.kind) or walk.text_is(text, "<");
        const closes = walk.is_close(token.kind) or walk.text_is(text, ">");

        if (opens) {
            depth += 1;
        } else if (closes) {
            depth -|= 1;
        } else if (depth == 0) {
            if (token.is_punctuation(.comma)) commas += 1;
        } else {}
    }

    return commas;
}

pub fn header_joined(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < emitter.count);

    if (!emitter.policy.header_joins) return false;

    const head = header_head(emitter, previous) orelse return false;
    const open = header_brace(emitter, head) orelse return false;
    if (position > open) return false;
    if (emitter.line_first > head) return false;
    if (parted_bracket(emitter, head, open) != null) return false;
    if (letting(emitter, head, open)) return false;
    if (!capped_spans(emitter, emitter.line_first, open)) return false;

    const stop = if (position == open) open else (emit.back_of(emitter, open) orelse return false);
    const width = header_width(emitter, emitter.line_first, stop) orelse return false;

    return emitter.printed * emitter.options.indent_width + width <= emitter.options.line_width;
}

fn lambda_chains(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    const named = lambda_named(emitter, open);
    const head = wide.chain_head(emitter, named);
    const last, const links, _ = wide.chain_end(emitter, head);

    if (links < 2) return true;
    if (head >= open) return true;
    if (last <= close) return true;

    const ahead = body.parted_by(emitter, emitter.tokens[head].end(), emitter.tokens[open].offset);
    const behind = body.parted_by(emitter, emitter.tokens[close].end(), emitter.tokens[last].end());
    if (ahead + behind > 0) return true;

    const width = flat_width(emitter, head, last) orelse return false;
    return width -| lambda_braces <= emitter.policy.chain_width;
}

fn lambda_named(emitter: *const Emitter, open: u32) u32 {
    assert(open < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    const frame = lambda_frame(emitter, open) orelse return open;
    return emit.back_of(emitter, frame) orelse open;
}

fn lambda_tries(emitter: *const Emitter, close: u32, end: u32) u32 {
    assert(close < emitter.count);
    assert(end < emitter.count);

    var tries: u32 = 0;
    var scan = close;

    for (0..define_scan_max) |_| {
        const held = emit.ahead_of(emitter, scan) orelse return tries;
        if (held > end) return tries;

        tries += @intFromBool(walk.text_is(emitter.tokens[held].text(emitter.source), "?"));
        scan = held;
    }

    return tries;
}

fn lambda_frame(emitter: *const Emitter, open: u32) ?u32 {
    assert(open < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    var depth: u32 = 0;
    var scan = open;

    for (0..define_scan_max) |_| {
        const held = emit.back_of(emitter, scan) orelse return null;
        const kind = emitter.tokens[held].kind;

        if (walk.is_close(kind)) {
            depth += 1;
        } else if (walk.is_open(kind)) {
            if (depth == 0) {
                if (kind == .block_start) return null;
                return held;
            }

            depth -= 1;
        } else {}

        scan = held;
    }

    return null;
}

fn lambda_hugged(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    var inner = true;
    var scan = open;

    for (0..brace.nest_depth_max) |_| {
        const frame = lambda_frame(emitter, scan) orelse return true;
        const close = closing_of(emitter, frame) orelse return true;
        const hugged = inner and lone_item(emitter, frame, close);

        assert(frame < scan);

        if (!hugged) {
            if (!lambda_fits(emitter, frame, close)) return false;
        }

        inner = false;
        scan = frame;
    }

    return false;
}

fn lambda_fits(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    const first, const last = inner_range(emitter, open, close) orelse return true;
    const width = flat_width(emitter, first, last) orelse return false;

    return width -| lambda_braces <= emitter.policy.call_width;
}

pub fn coded_before(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);

    var scan = emit.back_of(emitter, position) orelse return null;

    for (0..define_scan_max) |_| {
        assert(scan < position);

        if (emitter.tokens[scan].kind != .comment) return scan;

        scan = emit.back_of(emitter, scan) orelse return null;
    }

    return null;
}

fn lone_item(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    var depth: u32 = 0;
    var scan = open;

    for (0..define_scan_max) |_| {
        if (scan >= close) return true;

        const kind = emitter.tokens[scan].kind;

        if (walk.is_open(kind)) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            depth -|= 1;
        } else if (depth == 1) {
            const comma = kind.eql(.{ .punctuation = .comma });
            const listed = comma and emitter.brackets.angles_at(scan) == 0;
            if (listed) return false;
        } else {}

        scan = emit.ahead_of(emitter, scan) orelse return true;
    }

    return false;
}

fn lambda_macro(emitter: *const Emitter) bool {
    assert(emitter.depth <= brace.nest_depth_max);
    assert(emitter.count <= emitter.tokens.len);

    for (0..emitter.depth) |level| {
        const open = emitter.nest[level].open;
        const held = emit.back_of(emitter, open) orelse continue;
        if (emitter.tokens[held].is_punctuation(.bang)) return true;
    }

    return false;
}

fn lambda_bar(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    const held = emit.back_of(emitter, open) orelse return false;
    const text = emitter.tokens[held].text(emitter.source);
    if (walk.text_is(text, "|")) return true;
    if (!walk.text_is(text, "||")) return false;

    const found = emit.back_of(emitter, held) orelse return true;
    if (walk.is_open(emitter.tokens[found].kind)) return true;
    return worded(lambda_bar_heads, emitter.tokens[found].text(emitter.source));
}

fn typed_body(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    var arrow = false;
    var depth: u32 = 0;
    var scan = open;

    for (0..core.type_scan_max) |_| {
        const held = emit.back_of(emitter, scan) orelse return false;
        const kind = emitter.tokens[held].kind;

        if (walk.is_close(kind)) {
            depth += 1;
        } else if (walk.is_open(kind)) {
            if (depth == 0) return false;

            depth -= 1;
        } else if (depth == 0) {
            const text = emitter.tokens[held].text(emitter.source);

            if (walk.text_is(text, "->")) {
                arrow = true;
            } else if (typed_barred(text)) {
                return arrow;
            } else if (typed_stopped(emitter, held)) {
                return false;
            } else {}
        } else {}

        scan = held;
    }

    return false;
}

fn typed_barred(text: []const u8) bool {
    assert(text.len <= std.math.maxInt(u32));

    const result = walk.text_is(text, "|") or walk.text_is(text, "||");

    if (result) assert(text[0] == '|');

    return result;
}

fn typed_stopped(emitter: *const Emitter, held: u32) bool {
    assert(held < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    const token = emitter.tokens[held];
    if (worded(typed_stops, token.text(emitter.source))) return true;
    if (token.kind == .comment) return true;
    return line.word_is(emitter, held, emitter.policy.define_words);
}

fn block_shaped(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    if (!emitter.policy.block_joins) return false;
    return verdict_of(evaluated(emitter, .{ .shaped = shaped_frame(open) }));
}

fn shaped_frame(open: u32) Shaped {
    assert(open < std.math.maxInt(u32));

    const frame: Shaped = .{ .open = open, .first = 0, .last = 0, .phase = .start };

    assert(frame.phase == .start);

    return frame;
}

fn shaped_step(emitter: *const Emitter, frame: *Shaped, answer: ?Answer) Step {
    assert(frame.open < emitter.count);
    assert(emitter.count <= emitter.tokens.len);
    if (frame.phase == .start) assert(answer == null);

    switch (frame.phase) {
        .start => {
            const first, const last = shaped_body(emitter, frame.open) orelse
                return .{ .done = false };

            frame.first = first;
            frame.last = last;
            frame.phase = .run;

            return .{ .call = capped_frame(emitter, first, last, true, false) };
        },
        .run => {
            assert(frame.first <= frame.last);

            if (!verdict_of(answer)) return .{ .done = false };

            frame.phase = .parted;

            return .{ .call = parted_frame(emitter, frame.first, frame.last) };
        },
        .parted => return .{ .done = point_of(answer) == null },
    }
}

fn shaped_body(emitter: *const Emitter, open: u32) ?struct { u32, u32 } {
    assert(open < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    if (!emitter.policy.block_joins) return null;
    if (emitter.tokens[open].kind != .block_start) return null;

    const word = emit.back_of(emitter, open);
    const valued = shaped_valued(emitter, open, word);
    const before = if (word) |held| coded_before(emitter, held) else null;
    const marker = if (before) |held| emitter.tokens[held] else null;
    const closer = if (marker) |token| token.is_punctuation(.bracket_close) else false;
    const headed = shaped_headed(emitter, open, word);
    const close = emit.closing(emitter, open) orelse return null;

    if (!valued) return null;
    if (closer) return null;
    if (headed) return null;

    const first, const last = inner_range(emitter, open, close) orelse return null;
    if (!simple_body(emitter, first, last)) return null;
    if (!lone_item(emitter, open, close)) return null;
    return .{ first, last };
}

fn shaped_valued(emitter: *const Emitter, open: u32, word: ?u32) bool {
    assert(open < emitter.count);
    assert(emitter.count <= emitter.tokens.len);
    if (word) |held| assert(held < emitter.count);

    const held = word orelse return true;
    const token = emitter.tokens[held];
    const text = token.text(emitter.source);

    if (token.kind == .block_start) return true;
    if (walk.text_is(text, ";")) return true;
    if (walk.text_is(text, "=")) return true;
    if (worded(value_blocks, text)) return true;
    return typed_body(emitter, open);
}

fn shaped_headed(emitter: *const Emitter, open: u32, word: ?u32) bool {
    assert(open < emitter.count);
    assert(emitter.count <= emitter.tokens.len);
    if (word) |held| assert(held < emitter.count);

    const held = word orelse return false;
    const head = header_head(emitter, held) orelse return false;

    return header_brace(emitter, head) == open;
}

fn outer_line(emitter: *const Emitter, position: u32) ?struct { u32, u32 } {
    assert(position < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    var held = position;

    for (0..brace.nest_depth_max) |_| {
        const open = outer_brace(emitter, held) orelse break;
        if (!block_shaped(emitter, open)) break;

        held = open;
    }

    return line_lead(emitter, held);
}

fn outer_brace(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    var depth: u32 = 0;
    var scan = position;

    for (0..define_scan_max) |_| {
        const held = emit.back_of(emitter, scan) orelse return null;
        const kind = emitter.tokens[held].kind;

        if (walk.is_close(kind)) {
            depth += 1;
        } else if (walk.is_open(kind)) {
            if (depth == 0) {
                if (kind == .block_start) return held;
                return null;
            }

            depth -= 1;
        } else {}

        scan = held;
    }

    return null;
}

fn flat_span(emitter: *const Emitter, from: u32, to: u32) ?u32 {
    assert(from < emitter.count);
    assert(to < emitter.count);

    const width = header_width(emitter, from, to) orelse return null;
    var given: u32 = 0;
    var scan = from;

    for (0..define_scan_max) |_| {
        if (scan >= to) {
            assert(width -| given < std.math.maxInt(u32));

            return width -| given;
        }

        if (emitter.tokens[scan].kind == .block_start) {
            if (lambda_bar(emitter, scan)) given += lambda_braces;
        }

        scan = emit.ahead_of(emitter, scan) orelse {
            assert(given < std.math.maxInt(u32));

            return width -| given;
        };
    }

    return null;
}

fn block_chains(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    const dot = emit.ahead_of(emitter, close) orelse return true;
    if (!dot_linked(emitter, dot)) return true;

    _, const last, const links = chain_span(emitter, dot);

    if (links < 2) return true;
    if (last < dot) return true;

    const width = flat_span(emitter, open, last) orelse return false;
    return width <= emitter.policy.chain_width;
}

fn block_held(emitter: *const Emitter, block: u32) ?u32 {
    assert(block < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    const close = emit.closing(emitter, block) orelse return null;
    var held = emit.ahead_of(emitter, close) orelse return null;

    for (0..hug_nest_max) |_| {
        const text = emitter.tokens[held].text(emitter.source);
        const trailed = walk.text_is(text, "?") or walk.text_is(text, ",");
        if (!trailed) break;

        held = emit.ahead_of(emitter, held) orelse return null;
    }

    const token = emitter.tokens[held];
    const closed = token.is_punctuation(.paren_close) or token.is_punctuation(.bracket_close);
    if (!closed) return null;
    return emitter.brackets.open_of(held);
}

pub fn block_budgeted(emitter: *const Emitter, block: u32) bool {
    assert(block < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    if (!emitter.policy.call_budgets) return false;

    const held = block_held(emitter, block) orelse return false;
    const close = closing_of(emitter, held) orelse return false;

    if (closing_of(emitter, block)) |end| {
        if (emit.ahead_of(emitter, block) == end) return false;
    }

    const last = wide.listed_last(emitter, held, close) orelse held + 1;
    const ahead = wide.flat_columns(emitter, held + 1, last);
    const budget = wide.sole_budget(emitter, held) -| ahead;
    if (budget >= emitter.policy.call_width) return false;

    const overflows = hug_block(emitter, block) or lambda_bar(emitter, block);

    if (!overflows) {
        if (parted_items(emitter, held, close) != 1) return false;
    }

    return wide.flat_columns(emitter, held + 1, close) -| ahead > budget;
}

fn block_flat(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (!block_shaped(emitter, open)) return false;
    if (split.body_clauses(emitter, open)) return false;
    if (wide.block(emitter, open)) return false;

    const close = emit.closing(emitter, open) orelse return false;
    if (wide.hugged_over(emitter, open, close)) return false;
    if (streamed_lines(emitter, open, close)) return false;

    const head, const level = outer_line(emitter, open) orelse return false;

    if (!block_chains(emitter, open, close)) return false;

    const width = flat_span(emitter, head, flat_end(emitter, close)) orelse return false;
    return level * emitter.options.indent_width + width <= emitter.options.line_width;
}

fn streamed_lines(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    var scan = open + 1;

    while (scan < close) : (scan += 1) {
        if (!walk.is_open(emitter.tokens[scan].kind)) continue;

        const end = closing_of(emitter, scan) orelse continue;
        if (end >= close) continue;
        if (streamed_invoked(emitter, scan, end)) return true;
    }

    return false;
}

fn streamed_invoked(emitter: *const Emitter, open: u32, end: u32) bool {
    assert(open < end);
    assert(end < emitter.count);

    const bang = emit.word_before(emitter, open) orelse return false;
    if (!emitter.tokens[bang].is_punctuation(.bang)) return false;

    const from = emitter.tokens[open].end();
    const to = emitter.tokens[end].offset;
    if (body.parted_by(emitter, from, to) == 0) return false;
    return wide.streamed(emitter, open, end);
}

fn branch_pair(emitter: *const Emitter, position: u32, previous: u32) ?u32 {
    assert(position < emitter.count);
    assert(previous < emitter.count);

    const opening = branch_brace(emitter, position, previous) orelse return null;
    const word = emit.back_of(emitter, opening) orelse return null;
    if (!walk.text_is(emitter.tokens[word].text(emitter.source), "else")) return opening;

    const close = emit.back_of(emitter, word) orelse return null;
    return emit.opened(emitter, close);
}

fn branch_brace(emitter: *const Emitter, position: u32, previous: u32) ?u32 {
    assert(position < emitter.count);
    assert(previous < emitter.count);

    const held = emitter.tokens[previous].kind;
    const kind = emitter.tokens[position].kind;

    if (held == .block_start) return previous;
    if (kind == .block_end) return emit.opened(emitter, position);
    if (held != .block_end) return null;
    if (!walk.text_is(emitter.tokens[position].text(emitter.source), "else")) return null;
    return emit.opened(emitter, previous);
}

pub fn branch_inline(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    if (emitter.tokens[open].kind != .block_start) return false;
    if (block_flat(emitter, open)) return true;
    if (!emitter.policy.branch_joins) return false;

    const held = branch_pair(emitter, open, open) orelse return false;
    return branch_flat(emitter, held);
}

pub fn branch_joined(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < emitter.count);

    if (!emitter.policy.branch_joins) return false;
    if (emitter.policy.branch_width == 0) return false;

    const open = branch_pair(emitter, position, previous) orelse return false;
    return branch_flat(emitter, open);
}

pub fn branch_flat(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    const word = emit.back_of(emitter, open) orelse return false;
    const head = header_head(emitter, word) orelse return false;
    if (!line.word_is(emitter, head, emitter.policy.branch_words)) return false;

    if (emit.back_of(emitter, head)) |held| {
        if (walk.text_is(emitter.tokens[held].text(emitter.source), "else")) return false;
    }

    const close = emit.closing(emitter, open) orelse return false;
    const other = branch_else(emitter, open) orelse return false;
    const shut = emit.closing(emitter, other) orelse return false;

    if (!branch_simple(emitter, open, close)) return false;
    if (!branch_simple(emitter, other, shut)) return false;
    if (!branch_valued(emitter, head, shut)) return false;

    const narrow = header_width(emitter, head, shut) orelse return false;
    if (narrow > emitter.policy.branch_width) return false;

    const first, const level = line_lead(emitter, head) orelse
        .{ emitter.line_first, emitter.printed };

    const width = header_width(emitter, first, flat_end(emitter, shut)) orelse return false;
    return level * emitter.options.indent_width + width <= emitter.options.line_width;
}

fn branch_else(emitter: *const Emitter, open: u32) ?u32 {
    assert(open < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    const close = emit.closing(emitter, open) orelse return null;
    const word = emit.ahead_of(emitter, close) orelse return null;
    if (!walk.text_is(emitter.tokens[word].text(emitter.source), "else")) return null;

    const held = emit.ahead_of(emitter, word) orelse return null;
    if (emitter.tokens[held].kind != .block_start) return null;
    return held;
}

fn branch_simple(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    const first, const last = inner_range(emitter, open, close) orelse return false;
    return simple_body(emitter, first, last);
}

fn branch_valued(emitter: *const Emitter, head: u32, shut: u32) bool {
    assert(head < shut);
    assert(shut < emitter.count);

    if (emit.back_of(emitter, head)) |held| {
        const kind = emitter.tokens[held].kind;
        const braced = kind == .block_start or kind == .block_end;
        const statement = braced or kind.eql(.{ .punctuation = .semicolon });
        if (!statement) return true;
    }

    const end = emit.ahead_of(emitter, shut) orelse return false;
    if (line.word_is(emitter, end, &.{ ".", "?" })) return true;
    if (line.word_is(emitter, end, emitter.policy.continue_words)) return true;
    if (emitter.tokens[end].kind != .block_end) return false;

    const open = emit.opened(emitter, end) orelse return true;
    const arrow = emit.back_of(emitter, open) orelse return true;
    if (!walk.text_is(emitter.tokens[arrow].text(emitter.source), "=>")) return true;
    return emit.defined_branch(emitter, open);
}

fn lambdas(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    if (!emitter.policy.lambda_flattens) return false;
    return verdict_of(evaluated(emitter, .{ .lambdas = lambdas_frame(open) }));
}

fn lambdas_frame(open: u32) Lambdas {
    assert(open < std.math.maxInt(u32));

    return .{
        .open = open,
        .close = 0,
        .first = 0,
        .last = 0,
        .held = open,
        .scan = open,
        .climbs = 0,
        .level = 0,
        .width = 0,
        .phase = .start,
    };
}

fn lambdas_step(emitter: *const Emitter, frame: *Lambdas, answer: ?Answer) Step {
    assert(frame.open < emitter.count);
    assert(frame.climbs <= brace.nest_depth_max);
    if (frame.phase == .start) assert(answer == null);

    switch (frame.phase) {
        .start => {
            if (!lambdas_body(emitter, frame)) return .{ .done = false };

            frame.phase = .climb;
        },
        .climb => {
            if (!verdict_of(answer)) return lambdas_tail(emitter, frame);

            frame.held = frame.scan;
            frame.climbs += 1;
        },
        .end => return lambdas_ended(emitter, frame, point_of(answer)),
        .run => {
            if (!verdict_of(answer)) return .{ .done = false };

            frame.phase = .parted;

            return .{ .call = parted_frame(emitter, frame.first, frame.last) };
        },
        .parted => {
            if (point_of(answer) != null) return .{ .done = false };

            const reach = frame.level * emitter.options.indent_width + frame.width;
            return .{ .done = reach <= emitter.options.line_width };
        },
    }

    return lambdas_climb(emitter, frame);
}

fn lambdas_body(emitter: *const Emitter, frame: *Lambdas) bool {
    assert(frame.open < emitter.count);
    assert(frame.phase == .start);

    const open = frame.open;

    if (!emitter.policy.lambda_flattens) return false;
    if (!lambda_bar(emitter, open)) return false;

    const close = emit.closing(emitter, open) orelse return false;
    const first, const last = inner_range(emitter, open, close) orelse return false;
    if (line.word_is(emitter, first, lambda_blocks)) return false;
    if (lambda_macro(emitter)) return false;
    if (!simple_body(emitter, first, last)) return false;

    frame.close = close;
    frame.first = first;
    frame.last = last;

    return true;
}

fn lambdas_climb(emitter: *const Emitter, frame: *Lambdas) Step {
    assert(frame.phase == .climb);
    assert(frame.climbs <= brace.nest_depth_max);

    if (frame.climbs == brace.nest_depth_max) return lambdas_tail(emitter, frame);

    const open = outer_brace(emitter, frame.scan) orelse return lambdas_tail(emitter, frame);

    frame.scan = open;

    return .{ .call = .{ .shaped = shaped_frame(open) } };
}

fn lambdas_tail(emitter: *const Emitter, frame: *Lambdas) Step {
    assert(frame.first <= frame.last);
    assert(frame.close > frame.open);
    assert(frame.close < emitter.count);

    frame.phase = .end;

    return .{ .call = end_frame(frame.close) };
}

fn lambdas_ended(emitter: *const Emitter, frame: *Lambdas, ended: ?u32) Step {
    assert(frame.phase == .end);
    assert(frame.close > frame.open);
    if (ended) |held| assert(held < emitter.count);

    const end = ended orelse return .{ .done = false };

    const head, const level = line_lead(emitter, frame.held) orelse
        .{ emitter.line_first, emitter.printed };

    const width = flat_span(emitter, head, end) orelse return .{ .done = false };
    const tries = lambda_tries(emitter, frame.close, end);

    if (!lambda_hugged(emitter, frame.open)) return .{ .done = false };
    if (!lambda_chains(emitter, frame.open, frame.close)) return .{ .done = false };

    frame.level = level;
    frame.width = width + tries;
    frame.phase = .run;

    return .{ .call = capped_frame(emitter, frame.first, frame.last, true, false) };
}

pub fn chain_flat(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < emitter.count);

    if (!emitter.policy.chain_joins) return false;
    if (!emit.is_dot(emitter, position)) return false;
    if (emit.ranges(emitter, position)) return false;

    const head, const last, const links = chain_span(emitter, position);

    if (emit.back_of(emitter, head)) |held| {
        const kind = emitter.tokens[held].kind;
        if (kind == .comment) return false;
        if (kind == .block_end) return false;
    }

    const ended = chain_flat_ended(emitter, head, last);

    if (links == 0) return false;
    if (head > previous) return false;
    if (position > last) return false;
    if (!ended) return false;

    const chain = header_width(emitter, head, last) orelse return false;
    const stop = flat_end(emitter, last);
    const hugged = hugged_tail(emitter, head, stop);
    const hug_open: ?u32 = if (hugged) |found| found[0] else null;
    const tries: u32 = if (hugged) |found| found[1] else 0;
    const capped = capped_spans(emitter, head, hug_open orelse last);

    if (chain_kids(emitter, head, last) > 1) {
        if (chain > emitter.policy.chain_width) return false;
    }

    if (!capped) return false;
    return chain_flat_fits(emitter, head, last, stop, hug_open, tries);
}

fn chain_flat_ended(emitter: *const Emitter, head: u32, last: u32) bool {
    assert(head < emitter.count);
    assert(last < emitter.count);

    if (emit.is_dot(emitter, last)) return false;

    const text = emitter.tokens[head].text(emitter.source);
    if (std.mem.findScalar(u8, text, '\n') != null) return false;

    const held = emit.ahead_of(emitter, last) orelse return true;
    const token = emitter.tokens[held];

    assert(held > last);

    if (emit.is_dot(emitter, held)) return false;
    if (token.kind == .identifier) return false;
    if (token.kind == .comment) return false;
    return !walk.text_is(token.text(emitter.source), "?");
}

fn chain_flat_fits(
    emitter: *const Emitter,
    head: u32,
    last: u32,
    stop: u32,
    hug_open: ?u32,
    tries: u32,
) bool {
    assert(head <= last);
    assert(last <= stop);
    if (hug_open) |held| assert(held < emitter.count);
    assert(tries < std.math.maxInt(u32));

    const led = line_lead(emitter, head);
    const first = if (led) |found| found[0] else emitter.line_first;
    const level = if (led) |found| found[1] else emitter.printed;
    const under = level * emitter.options.indent_width;
    const line_width = emitter.options.line_width;

    if (assign_lefted(emitter, last)) |margin| {
        if (header_width(emitter, first, last)) |width| {
            if (under + width + margin <= line_width) return true;
        }
    }

    if (hug_open) |open| {
        if (header_width(emitter, first, open)) |width| {
            if (under + width + hug_room + hug_tries * tries <= line_width) return true;
        }
    }

    const owed = wide.element_owed(emitter, first, head, last);
    const ended = if (owed) last else stop;
    const width = header_width(emitter, first, ended) orelse return false;

    return under + width + @intFromBool(owed) <= line_width;
}

fn assign_lefted(emitter: *const Emitter, last: u32) ?u32 {
    assert(last < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    const next = emit.ahead_of(emitter, last) orelse return null;
    const token = emitter.tokens[next];

    assert(next > last);

    if (!worded(arm_assigns, token.text(emitter.source))) return null;
    const returned = walk.columns(emitter.source, token.offset, token.end()) + 2;

    assert(returned < std.math.maxInt(u32));

    return returned;
}

pub fn root_joined(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < emitter.count);

    if (!emitter.policy.root_joins) return false;
    if (!emit.is_dot(emitter, position)) return false;
    if (emit.ranges(emitter, position)) return false;

    const led = line_lead(emitter, previous);
    const first = if (led) |found| found[0] else emitter.line_first;
    const head, _, _ = chain_span(emitter, position);

    if (first > previous) return false;
    if (head < first) return false;
    if (walk.is_close(emitter.tokens[first].kind)) return false;

    const width = header_width(emitter, first, previous) orelse return false;
    return width <= emitter.options.indent_width;
}

pub fn macro_joined(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.policy.special_macros.len == 0) return false;
    if (emitter.depth == 0) return false;

    const frame = emitter.nest[emitter.depth - 1];
    if (!frame.kind.eql(.{ .punctuation = .paren_open })) return false;

    const leading = macro_leading(emitter, frame.open) orelse return false;
    const close = closing_of(emitter, frame.open) orelse return false;

    const index, const items = macro_index(emitter, frame.open, close, position) orelse
        return false;

    if (items <= leading) return false;
    if (index == 0) return false;
    if (index == leading) return false;
    if (index == leading + 1) return false;

    if (flat_run(emitter, frame.open, close)) |width| {
        if (width <= emitter.policy.call_width) return false;
    } else {
        if (!wide.strung_spans(emitter, frame.open + 1, close)) return false;
    }

    return macro_packed(emitter, frame.open, close, leading);
}

fn macro_leading(emitter: *const Emitter, open: u32) ?u32 {
    assert(open < emitter.count);
    assert(emitter.policy.special_macros.len > 0);

    const bang = emit.back_of(emitter, open) orelse return null;
    if (!walk.text_is(emitter.tokens[bang].text(emitter.source), "!")) return null;

    const name = emit.back_of(emitter, bang) orelse return null;

    if (emit.back_of(emitter, name)) |held| {
        if (walk.text_is(emitter.tokens[held].text(emitter.source), "::")) return null;
    }

    const text = emitter.tokens[name].text(emitter.source);

    for (emitter.policy.special_macros) |special| {
        if (walk.text_eql(special.word, text)) return special.leading;
    }

    return null;
}

fn macro_index(
    emitter: *const Emitter,
    open: u32,
    close: u32,
    position: u32,
) ?struct { u32, u32 } {
    assert(open < close);
    assert(close < emitter.count);

    var depth: u32 = 0;
    var index: ?u32 = null;
    var items: u32 = 1;
    var last = open;
    var scan = open;

    for (0..define_scan_max) |_| {
        const next = emit.ahead_of(emitter, scan) orelse return null;

        if (next >= close) {
            if (emitter.tokens[last].is_punctuation(.comma)) items -= 1;

            const found = index orelse return null;
            return .{ found, items };
        }

        const kind = emitter.tokens[next].kind;

        if (walk.is_open(kind)) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            depth -|= 1;
        } else if (depth == 0) {
            if (kind.eql(.{ .punctuation = .comma })) items += 1;
        } else {}

        if (next == position) {
            if (depth == 0) index = items - 1;
        }

        last = next;
        scan = next;
    }

    return null;
}

fn macro_item(emitter: *const Emitter, open: u32, close: u32, index: u32) ?u32 {
    assert(open < close);
    assert(close < emitter.count);

    var depth: u32 = 0;
    var items: u32 = 0;
    var scan = open;

    for (0..define_scan_max) |_| {
        const next = emit.ahead_of(emitter, scan) orelse return null;
        if (next >= close) return null;

        const kind = emitter.tokens[next].kind;

        if (walk.is_open(kind)) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            depth -|= 1;
        } else if (depth == 0) {
            if (kind.eql(.{ .punctuation = .comma })) {
                items += 1;
                scan = next;

                continue;
            }
        } else {}

        if (items == index) return next;

        scan = next;
    }

    return null;
}

fn macro_packed(emitter: *const Emitter, open: u32, close: u32, leading: u32) bool {
    assert(open < close);
    assert(close < emitter.count);
    assert(leading < std.math.maxInt(u32));

    const string = macro_item(emitter, open, close, leading) orelse return false;
    const after = macro_item(emitter, open, close, leading + 1);
    const stop = after orelse close;
    if (!macro_packed_plain(emitter, open, close, string, stop)) return false;

    const held = leading == 0 or macro_run(emitter, open, emit.back_of(emitter, string));
    if (!held) return false;

    const found = after orelse return true;
    const comma = emit.back_of(emitter, found) orelse return false;

    return macro_run(emitter, comma, close);
}

fn macro_packed_plain(emitter: *const Emitter, open: u32, close: u32, string: u32, stop: u32) bool {
    assert(open < string);
    assert(string <= stop);

    const under = emitter.printed * emitter.options.indent_width;
    var scan = open;

    for (0..define_scan_max) |_| {
        const next = emit.ahead_of(emitter, scan) orelse return false;
        if (next >= close) return true;

        const token = emitter.tokens[next];
        const outside = next < string or next >= stop;

        if (outside) {
            const width = under + walk.columns(emitter.source, token.offset, token.end());
            if (width > emitter.options.line_width) return false;
            if (!macro_plain(emitter, next)) return false;
        }

        scan = next;
    }

    return true;
}

fn macro_run(emitter: *const Emitter, from: u32, to: ?u32) bool {
    assert(from < emitter.count);
    assert(emitter.count <= emitter.tokens.len);
    if (to) |held| assert(held < emitter.count);

    const first = emit.ahead_of(emitter, from) orelse return false;
    const held = to orelse return false;
    const end = emit.back_of(emitter, held) orelse return false;
    if (first > end) return false;

    const under = emitter.printed * emitter.options.indent_width;
    const width = header_width(emitter, first, end) orelse return false;

    return under + width <= emitter.options.line_width;
}

fn macro_plain(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    const token = emitter.tokens[position];
    const text = token.text(emitter.source);

    switch (token.kind) {
        .identifier, .number, .string => return std.mem.findScalar(u8, text, '\n') == null,
        .keyword => return worded(macro_keywords, text),
        .punctuation => |punctuation| return macro_plain_mark(emitter, position, punctuation),
        .block_end, .block_start, .comment, .newline => return macro_plain_other(emitter, position),
    }
}

fn macro_plain_mark(emitter: *const Emitter, position: u32, punctuation: Token.Punctuation) bool {
    assert(position < emitter.count);
    assert(emitter.tokens[position].kind == .punctuation);

    switch (punctuation) {
        .dot => return emit.is_dot(emitter, position),
        .bracket_close, .bracket_open, .comma => return true,
        .ampersand, .star => return macro_prefix(emitter, position),
        else => return macro_plain_other(emitter, position),
    }
}

fn macro_plain_other(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    const text = emitter.tokens[position].text(emitter.source);
    if (walk.text_is(text, "?")) return true;
    if (!worded(macro_prefixes, text)) return false;
    return macro_prefix(emitter, position);
}

fn macro_prefix(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    const held = emit.back_of(emitter, position) orelse return true;

    assert(held < position);

    return !emit.operand_at(emitter, held);
}

fn flat_run(emitter: *const Emitter, open: u32, close: u32) ?u32 {
    assert(open < close);
    assert(close < emitter.count);

    const first = emit.ahead_of(emitter, open) orelse return null;
    const end = emit.back_of(emitter, close) orelse return null;
    if (first > end) return null;
    return header_width(emitter, first, end);
}

pub fn mixed_filled(emitter: *const Emitter, position: u32) ?bool {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.policy.list_mixes == 0) return null;
    if (emitter.depth == 0) return null;

    const frame = emitter.nest[emitter.depth - 1];
    const bracketed = frame.kind.eql(.{ .punctuation = .bracket_open });
    const listed = bracketed or frame.kind.eql(.{ .punctuation = .paren_open });
    if (!listed) return null;

    const close = closing_of(emitter, frame.open) orelse return null;
    const previous = emitter.previous orelse return null;

    if (position > close) return null;
    if (wide.attribute_head(emitter) != null) return null;
    if (wide.bound_patterned(emitter, frame.open)) return null;
    if (line.worded_head(emitter, frame.open, mixed_refused)) return null;

    if (previous != frame.open) {
        if (!emitter.tokens[previous].is_punctuation(.comma)) return null;
    }

    const index, const items = macro_index(emitter, frame.open, close, position) orelse
        return null;

    if (items < 2) return null;
    if (!mixed_short(emitter, frame.open, close, items)) return null;

    return mixed_filled_wide(emitter, .{
        .position = position,
        .previous = previous,
        .open = frame.open,
        .close = close,
        .index = index,
        .items = items,
    });
}

fn mixed_filled_wide(emitter: *const Emitter, fill: MixedFill) ?bool {
    assert(fill.open < fill.close);
    assert(fill.index <= fill.items);

    const under = emitter.printed * emitter.options.indent_width;
    const flat = flat_run(emitter, fill.open, fill.close) orelse return null;
    const budget = wide.sole_budget(emitter, fill.open);

    if (flat <= budget) {
        if (under + flat <= emitter.options.line_width) return null;
    }

    if (fill.previous == fill.open) return true;

    const end = mixed_end(emitter, fill.open, fill.close, fill.index) orelse return null;
    const item = header_width(emitter, fill.position, end) orelse return null;
    const width = item + @intFromBool(fill.index + 1 < fill.items);
    const before = header_width(emitter, emitter.line_first, fill.previous) orelse return null;
    const column = under + before;

    return column + width + mixed_margin > emitter.options.line_width;
}

pub fn mixed_joined(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.policy.list_mixes == 0) return false;
    if (emitter.depth == 0) return false;

    const frame = emitter.nest[emitter.depth - 1];
    if (!frame.kind.eql(.{ .punctuation = .bracket_open })) return false;
    if (wide.bound_patterned(emitter, frame.open)) return false;

    const close = closing_of(emitter, frame.open) orelse return false;
    if (position > close) return false;

    const index, const items = macro_index(emitter, frame.open, close, position) orelse
        return false;

    const under = emitter.printed * emitter.options.indent_width;
    const width = flat_run(emitter, frame.open, close) orelse return false;
    const line_width = emitter.options.line_width;
    const vertical = width > emitter.policy.call_width or under + width > line_width;
    const filled = under + width < line_width;

    if (index == 0) return false;
    if (items <= 1) return false;
    if (!vertical) return false;
    if (!filled) return false;
    return mixed_short(emitter, frame.open, close, items);
}

fn mixed_end(emitter: *const Emitter, open: u32, close: u32, index: u32) ?u32 {
    assert(open < close);
    assert(close < emitter.count);
    assert(index < emitter.count);

    const next = macro_item(emitter, open, close, index + 1) orelse
        return emit.back_of(emitter, close);

    const comma = emit.back_of(emitter, next) orelse return null;
    return emit.back_of(emitter, comma);
}

fn mixed_short(emitter: *const Emitter, open: u32, close: u32, items: u32) bool {
    assert(open < close);
    assert(items > 0);

    for (0..@min(items, define_scan_max)) |item| {
        const index: u32 = @intCast(item);
        const from = macro_item(emitter, open, close, index) orelse return false;
        const to = mixed_end(emitter, open, close, index) orelse return false;
        if (from > to) return false;

        const width = header_width(emitter, from, to) orelse return false;
        if (width > emitter.policy.list_mixes) return false;
        if (!mixed_short_plain(emitter, from, to)) return false;
    }

    return true;
}

fn mixed_short_plain(emitter: *const Emitter, from: u32, to: u32) bool {
    assert(from <= to);
    assert(to < emitter.count);

    var scan = from;

    for (0..define_scan_max) |_| {
        if (!macro_plain(emitter, scan)) return false;
        if (scan >= to) return true;

        scan = emit.ahead_of(emitter, scan) orelse return false;
    }

    return true;
}

pub fn hug_joined(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (!emitter.policy.hug_lambdas) return false;
    if (emitter.depth == 0) return false;

    const frame = emitter.nest[emitter.depth - 1];
    if (!frame.kind.eql(.{ .punctuation = .paren_open })) return false;

    const close = closing_of(emitter, frame.open) orelse return false;
    const block = hug_lambda(emitter, frame.open) orelse return false;

    if (position <= frame.open) return false;
    if (block > close) return false;

    if (position > block) {
        if (position != close) return false;
    }

    const first, const level = line_lead(emitter, frame.open) orelse return false;
    const room = lambda_room(emitter, frame.open, block);
    const head = emit.ahead_of(emitter, frame.open) orelse return false;
    const inside = header_width(emitter, head, block) orelse return false;
    if (inside > room) return false;
    if (first > frame.open) return false;

    const width = header_width(emitter, first, block) orelse return false;
    return level * emitter.options.indent_width + width < emitter.options.line_width;
}

fn derive_next(emitter: *const Emitter, close: u32) ?u32 {
    assert(close < emitter.count);

    if (!emitter.policy.attribute_ends) return null;
    if (!emitter.tokens[close].is_punctuation(.paren_close)) return null;

    const open = emitter.brackets.open_of(close) orelse return null;
    if (emit.ahead_of(emitter, open) == close) return null;

    const held = emit.back_of(emitter, open) orelse return null;
    if (!walk.text_is(emitter.tokens[held].text(emitter.source), "derive")) return null;

    const bracket = emit.back_of(emitter, held) orelse return null;
    const hash = emit.back_of(emitter, bracket) orelse return null;

    if (!emitter.tokens[bracket].is_punctuation(.bracket_open)) return null;
    if (!walk.text_is(emitter.tokens[hash].text(emitter.source), "#")) return null;

    const paren = derive_matched(emitter, close) orelse return null;

    if (closing_of(emitter, paren)) |end| {
        if (emit.ahead_of(emitter, paren) == end) return null;
    }

    return paren;
}

fn derive_matched(emitter: *const Emitter, close: u32) ?u32 {
    assert(close < emitter.count);
    assert(emitter.policy.attribute_ends);

    const shut = emit.ahead_of(emitter, close) orelse return null;
    const mark = emit.ahead_of(emitter, shut) orelse return null;
    const opened = emit.ahead_of(emitter, mark) orelse return null;
    const named = emit.ahead_of(emitter, opened) orelse return null;
    const paren = emit.ahead_of(emitter, named) orelse return null;

    if (!emitter.tokens[shut].is_punctuation(.bracket_close)) return null;
    if (!walk.text_is(emitter.tokens[mark].text(emitter.source), "#")) return null;
    if (!emitter.tokens[opened].is_punctuation(.bracket_open)) return null;
    if (!walk.text_is(emitter.tokens[named].text(emitter.source), "derive")) return null;
    if (!emitter.tokens[paren].is_punctuation(.paren_open)) return null;
    return paren;
}

pub fn derive_dropped(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    var scan = position;

    for (0..derive_walk_max) |_| {
        assert(scan <= position);

        if (derive_next(emitter, scan)) |end| {
            if (position <= end) return true;
        }

        scan = emit.back_of(emitter, scan) orelse return false;
    }

    return false;
}

pub fn derive_added(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    const open = emit.back_of(emitter, position) orelse return false;
    var scan = open;

    for (0..derive_walk_max) |_| {
        scan = emit.back_of(emitter, scan) orelse return false;

        assert(scan < open);

        if (derive_next(emitter, scan) == open) return true;
    }

    return false;
}

fn hug_nested(emitter: *const Emitter, outer: u32) ?struct { u32, u32 } {
    assert(outer < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    var close = closing_of(emitter, outer) orelse return null;
    var head = outer;

    for (0..hug_nest_max) |_| {
        const last = hug_nested_last(emitter, close) orelse return null;
        const kind = emitter.tokens[last].kind;

        if (last <= head) return .{ head, close };
        if (kind == .block_end) return .{ head, close };
        if (!walk.is_close(kind)) return .{ head, close };

        const inner = emitter.brackets.open_of(last) orelse return .{ head, close };
        if (inner <= head) return .{ head, close };
        if (parted_items(emitter, head, close) != 1) return .{ head, close };
        if (!hug_direct(emitter, head, inner)) return .{ head, close };

        const columns = wide.flat_columns(emitter, head + 1, close);
        if (columns <= emitter.policy.call_width) return .{ head, close };

        close = last;
        head = inner;
    }

    return .{ head, close };
}

fn hug_nested_last(emitter: *const Emitter, close: u32) ?u32 {
    assert(close < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    var last = emit.back_of(emitter, close) orelse return null;

    for (0..hug_nest_max) |_| {
        const text = emitter.tokens[last].text(emitter.source);
        const trailing = walk.text_is(text, "?") or walk.text_is(text, ",");
        if (!trailing) break;

        last = emit.back_of(emitter, last) orelse return null;
    }

    return last;
}

fn hug_lambda(emitter: *const Emitter, outer: u32) ?u32 {
    assert(outer < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    const open, const close = hug_nested(emitter, outer) orelse return null;
    var held = emit.back_of(emitter, close) orelse return null;

    if (emitter.tokens[held].is_punctuation(.comma)) {
        held = emit.back_of(emitter, held) orelse return null;
    }

    for (0..hug_nest_max) |_| {
        if (!walk.text_is(emitter.tokens[held].text(emitter.source), "?")) break;

        held = emit.back_of(emitter, held) orelse return null;
    }

    if (emitter.tokens[held].kind != .block_end) return null;

    const found = hug_lambda_open(emitter, open, held) orelse return null;
    return hug_lambda_found(emitter, open, close, found);
}

fn hug_lambda_open(emitter: *const Emitter, open: u32, held: u32) ?u32 {
    assert(open < held);
    assert(held < emitter.count);

    var depth: u32 = 0;
    var scan = held;

    for (0..define_scan_max) |_| {
        const found = emit.back_of(emitter, scan) orelse return null;
        if (found <= open) return null;

        const kind = emitter.tokens[found].kind;

        if (walk.is_close(kind)) {
            depth += 1;
        } else if (walk.is_open(kind)) {
            if (depth == 0) {
                if (kind != .block_start) return null;
                return found;
            }

            depth -= 1;
        } else {}

        scan = found;
    }

    return null;
}

fn hug_lambda_found(emitter: *const Emitter, open: u32, close: u32, found: u32) ?u32 {
    assert(open < found);
    assert(found < close);

    const blocked = lambda_bar(emitter, found) or hug_block(emitter, found);
    const items = parted_items(emitter, open, close);

    if (emitter.policy.hug_lambdas) {
        if (lambda_bar(emitter, found)) {
            if (lambdas_in(emitter, open, close) > 1) return null;
        }
    }

    if (items == 0) return null;

    const head = macro_item(emitter, open, close, items - 1) orelse return null;
    const text = emitter.tokens[head].text(emitter.source);
    if (walk.text_is(text, "#")) return null;
    if (worded(hug_refused, text)) return null;
    if (blocked) return found;
    if (items == 1) return found;
    return null;
}

pub fn lambdas_in(emitter: *const Emitter, open: u32, close: u32) u32 {
    assert(open < close);
    assert(close < emitter.count);

    var lambda_count: u32 = 0;
    var depth: u32 = 0;
    var leading = true;
    var scan = open;

    for (0..define_scan_max) |_| {
        const next = emit.ahead_of(emitter, scan) orelse return lambda_count;
        if (next >= close) return lambda_count;

        const kind = emitter.tokens[next].kind;
        const text = emitter.tokens[next].text(emitter.source);
        const headed = depth == 0 and leading;

        scan = next;

        if (headed) {
            if (worded(lambda_words, text)) continue;

            if (walk.text_is(text, "||")) {
                lambda_count += 1;
                leading = false;

                continue;
            }

            if (walk.text_is(text, "|")) {
                lambda_count += 1;
                leading = false;
                scan = lambda_end(emitter, next, close);

                continue;
            }
        }

        leading = false;

        if (walk.is_open(kind)) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            depth -|= 1;
        } else if (depth == 0) {
            if (kind.eql(.{ .punctuation = .comma })) leading = true;
        } else {}
    }

    return lambda_count;
}

fn lambda_end(emitter: *const Emitter, bar: u32, close: u32) u32 {
    assert(bar < close);
    assert(close < emitter.count);

    var depth: u32 = 0;
    var scan = bar;

    for (0..define_scan_max) |_| {
        const next = emit.ahead_of(emitter, scan) orelse return close;
        if (next >= close) return close;

        const kind = emitter.tokens[next].kind;

        if (walk.is_open(kind)) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            depth -|= 1;
        } else if (depth == 0) {
            if (walk.text_is(emitter.tokens[next].text(emitter.source), "|")) return next;
        } else {}

        scan = next;
    }

    return close;
}

pub fn operand_joined(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < emitter.count);

    if (!emitter.policy.operand_joins) return false;
    if (!logical(emitter, position)) return false;
    if (!emit.operand_at(emitter, previous)) return false;
    if (line.attributed(emitter, previous)) return false;

    const head = operand_head(emitter, position) orelse return false;
    const end = operand_end(emitter, position) orelse return false;
    const first, const level = line_lead(emitter, head) orelse return false;
    if (operand_orphaned(emitter, head, first, previous)) return false;

    const owed = operand_owed(emitter, end);

    if (first > head) return false;
    if (operand_letting(emitter, first, end)) return false;
    if (!capped_spans(emitter, first, end)) return false;

    const width = header_width(emitter, first, end) orelse return false;
    return level * emitter.options.indent_width + width + owed <= emitter.options.line_width;
}

fn operand_owed(emitter: *const Emitter, end: u32) u32 {
    assert(end < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    const held = emit.ahead_of(emitter, end) orelse return 1;

    assert(held > end);

    if (walk.text_is(emitter.tokens[held].text(emitter.source), "=>")) return arm_pattern_room;
    return @intFromBool(emitter.tokens[held].kind != .block_end);
}

fn operand_letting(emitter: *const Emitter, from: u32, to: u32) bool {
    assert(from <= to);
    assert(to < emitter.count);

    if (walk.text_is(emitter.tokens[from].text(emitter.source), "let")) return false;

    var scan = from;

    for (0..define_scan_max) |_| {
        if (walk.text_is(emitter.tokens[scan].text(emitter.source), "let")) return true;
        if (scan >= to) return false;

        scan = emit.ahead_of(emitter, scan) orelse return true;
    }

    return true;
}

fn operand_orphaned(emitter: *const Emitter, head: u32, first: u32, previous: u32) bool {
    assert(head < emitter.count);
    assert(first < emitter.count);
    assert(previous < emitter.count);

    const kind = emitter.tokens[first].kind;

    if (!emitter.policy.index_continues) return false;
    if (first >= head) return false;

    const closed = kind == .block_end or walk.is_close(kind);
    if (!closed) return false;

    const width = header_width(emitter, first, previous) orelse return true;
    const indent = emitter.options.indent_width;

    return emitter.printed * indent + width > (emitter.printed + 1) * indent;
}

fn operand_head(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    var depth: u32 = 0;
    var first = position;
    var scan = position;

    for (0..define_scan_max) |_| {
        const held = emit.back_of(emitter, scan) orelse return null;
        const kind = emitter.tokens[held].kind;

        if (bind.hole_open(emitter, held)) |hole| {
            first = hole;
            scan = hole;

            continue;
        }

        if (depth == 0) {
            if (kind == .block_end) {
                if (!wide.operand_brace(emitter, held)) return first;
            }
        }

        if (walk.is_close(kind)) {
            depth += 1;
        } else if (walk.is_open(kind)) {
            if (depth == 0) return first;

            depth -= 1;
        } else if (depth == 0) {
            switch (operand_head_stop(emitter, held)) {
                .refused => return null,
                .stopped => return first,
                .walked => {},
            }
        } else {}

        first = held;
        scan = held;
    }

    return null;
}

fn operand_head_stop(emitter: *const Emitter, held: u32) OperandStop {
    assert(held < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    const token = emitter.tokens[held];
    const text = token.text(emitter.source);

    if (token.kind == .comment) return .refused;
    if (walk.text_is(text, ">")) return .refused;
    if (token.is_punctuation(.assign)) return .stopped;
    if (token.is_punctuation(.comma)) return .stopped;
    if (token.is_punctuation(.semicolon)) return .stopped;
    if (worded(operand_stops, text)) return .stopped;
    if (!walk.text_is(text, "|")) return .walked;
    if (operand_bar(emitter, held)) return .walked;
    return .stopped;
}

fn operand_bar(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    const held = emit.back_of(emitter, position) orelse return false;

    assert(held < position);

    if (wide.operand_brace(emitter, held)) return true;
    return emit.operand_at(emitter, held);
}

fn logical(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    const token = emitter.tokens[position];
    const text = token.text(emitter.source);
    if (worded(operand_joins, text)) return true;
    if (!walk.text_is(text, "&")) return false;

    const held = emit.ahead_of(emitter, position) orelse return false;
    const next = emitter.tokens[held];
    if (!walk.text_is(next.text(emitter.source), "&")) return false;
    return next.offset == token.end();
}

fn operand_end(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    var depth: u32 = 0;
    var last = position;
    var scan = position;
    var valued = false;

    for (0..define_scan_max) |_| {
        const next = emit.ahead_of(emitter, scan) orelse return null;
        const kind = emitter.tokens[next].kind;
        const text = emitter.tokens[next].text(emitter.source);

        const opened = depth == 0 and kind == .block_start and !valued and
            !wide.valued_brace(emitter, next);

        if (opened) return last;

        if (depth == 0) {
            if (walk.text_is(text, "=>")) return last;
        }

        if (worded(value_heads, text)) valued = true;

        if (walk.is_open(kind)) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            if (depth == 0) return last;

            depth -= 1;
        } else if (depth == 0) {
            if (kind.eql(.{ .punctuation = .comma })) return last;
            if (kind.eql(.{ .punctuation = .semicolon })) return last;
            if (walk.text_is(text, "<")) return null;
        } else {}

        last = next;
        scan = next;
    }

    return null;
}

pub fn chain_hugged(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (!emitter.policy.chain_hugs) return false;
    if (!emit.is_dot(emitter, position)) return false;
    if (emit.ranges(emitter, position)) return false;

    if (emitter.depth > 0) {
        if (armed_frame(emitter, emitter.nest[emitter.depth - 1].open)) return false;
    }

    const head, const last, const links = chain_span(emitter, position);
    const tail = chain_tail(emitter, head, last) orelse return false;
    const before = emit.back_of(emitter, tail) orelse return false;

    if (links == 0) return false;
    if (chain_commented(emitter, last)) return false;
    if (head > position) return false;
    if (position > tail) return false;
    if (head > before) return false;

    const open = chain_call(emitter, tail, last) orelse return false;
    const kids = chain_kids(emitter, head, last);
    const first, const level = line_lead(emitter, head) orelse return false;
    const under = level * emitter.options.indent_width;
    const almost = header_width(emitter, head, before) orelse return false;
    const widened = almost + wide.chain_tries(emitter, head, last);
    const hugged = chain_shown(emitter, open, kids, tail, last, under);
    const stop = hugged orelse open;
    const shown = header_width(emitter, tail, stop) orelse return false;
    const chain_width = emitter.policy.chain_width;

    if (links != 1) {
        if (widened >= chain_width) return false;
        if (shown > chain_width - widened) return false;
    }

    if (hugged == null) {
        if (chain_lasted(emitter, open, tail, last, under)) return false;
    }

    if (!chain_hugged_parted(emitter, open, hugged)) return false;
    if (first > head) return false;

    const width = header_width(emitter, first, stop) orelse return false;
    return under + width <= emitter.options.line_width;
}

fn chain_commented(emitter: *const Emitter, last: u32) bool {
    assert(last < emitter.count);

    var scan = emit.ahead_of(emitter, last) orelse return false;
    if (emitter.tokens[scan].kind != .comment) return false;

    for (0..define_scan_max) |_| {
        if (emitter.tokens[scan].kind != .comment) return chain_member(emitter, scan);

        scan = emit.ahead_of(emitter, scan) orelse return false;
    }

    return false;
}

fn chain_hugged_parted(emitter: *const Emitter, open: u32, hugged: ?u32) bool {
    assert(open < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    if (hugged != null) return true;

    const close = closing_of(emitter, open) orelse return false;
    const args = flat_run(emitter, open, close) orelse return false;
    if (args <= emitter.policy.call_width) return false;
    if (hug_lambda(emitter, open) != null) return false;
    return parted_items(emitter, open, close) > 1;
}

pub fn sole_joined(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (!emitter.policy.sole_joins) return false;
    if (emitter.depth == 0) return false;

    const frame = emitter.nest[emitter.depth - 1];
    if (!frame.kind.eql(.{ .punctuation = .paren_open })) return false;

    const close = closing_of(emitter, frame.open) orelse return false;

    if (position <= frame.open) return false;
    if (position > close) return false;
    if (parted_items(emitter, frame.open, close) != 1) return false;
    if (wide.defined(emitter, frame.open)) return false;
    if (hugged_brace(emitter, frame.open, close) != null) return false;

    const first, const level = line_lead(emitter, frame.open) orelse return false;
    const budget = wide.sole_budget(emitter, frame.open);
    const capped = sole_joined_capped(emitter, frame.open, close, budget);
    const held = sole_joined_held(emitter, frame.open, close);
    const returned = wide.returned_room(emitter, first);

    if (!capped) return false;
    if (!held) return false;
    if (first > frame.open) return false;

    const head = emit.ahead_of(emitter, frame.open) orelse return false;
    if (!capped_spans(emitter, head, close)) return false;

    const width = header_width(emitter, first, close) orelse return false;
    const indent = emitter.options.indent_width;
    const owed = sole_owed(emitter) + wide.arm_owed(emitter, close);

    return level * indent + width + owed + returned <= emitter.options.line_width;
}

fn sole_joined_capped(emitter: *const Emitter, open: u32, close: u32, budget: u32) bool {
    assert(open < close);
    assert(close < emitter.count);
    assert(budget < std.math.maxInt(u32));

    if (flat_run(emitter, open, close)) |width| {
        if (width <= budget) return true;
    }

    if (budget != emitter.policy.call_width) return false;
    return !sole_nested(emitter, open, close);
}

fn sole_joined_held(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    if (!sole_capped(emitter)) return true;

    const head = sole_head(emitter, open) orelse return false;
    const width = header_width(emitter, head, close) orelse return false;

    return width < emitter.policy.call_width;
}

fn sole_owed(emitter: *const Emitter) u32 {
    assert(emitter.depth <= brace.nest_depth_max);

    var owed: u32 = 1;

    for (0..emitter.depth -| 1) |level| {
        const kind = emitter.nest[level].kind;
        const parenthesized = kind.eql(.{ .punctuation = .paren_open });
        const listed = parenthesized or kind.eql(.{ .punctuation = .bracket_open });

        if (listed) owed += 1;
    }

    assert(owed <= emitter.depth + 1);

    return owed;
}

fn sole_capped(emitter: *const Emitter) bool {
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.depth < 2) return false;

    const outer = emitter.nest[emitter.depth - 2];
    const parenthesized = outer.kind.eql(.{ .punctuation = .paren_open });
    const listed = parenthesized or outer.kind.eql(.{ .punctuation = .bracket_open });
    if (!listed) return false;

    const close = closing_of(emitter, outer.open) orelse return false;

    assert(close > outer.open);

    return parted_items(emitter, outer.open, close) == 1;
}

fn sole_head(emitter: *const Emitter, open: u32) ?u32 {
    assert(open < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    var head = emit.back_of(emitter, open) orelse return null;
    const kind = emitter.tokens[head].kind;
    const named = kind == .identifier or kind == .keyword;
    if (!named) return null;

    for (0..brace.nest_depth_max) |_| {
        const joint = emit.back_of(emitter, head) orelse return head;
        const text = emitter.tokens[joint].text(emitter.source);
        const joined = walk.text_is(text, "::") or walk.text_is(text, "!");
        if (!joined) return head;

        head = emit.back_of(emitter, joint) orelse return head;
    }

    return head;
}

fn sole_nested(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    var held = emit.back_of(emitter, close) orelse return false;

    if (emitter.tokens[held].is_punctuation(.comma)) {
        const prior = emit.back_of(emitter, held) orelse return false;
        if (prior <= open) return false;

        held = prior;
    }

    for (0..brace.nest_depth_max) |_| {
        if (!walk.text_is(emitter.tokens[held].text(emitter.source), "?")) break;

        held = emit.back_of(emitter, held) orelse return false;
    }

    if (!emitter.tokens[held].is_punctuation(.paren_close)) return false;

    const inner = emit.opened(emitter, held) orelse return false;
    if (inner <= open) return false;

    const named = emit.back_of(emitter, inner) orelse return false;
    const kind = emitter.tokens[named].kind;
    const word = kind == .identifier or kind == .keyword;
    if (!word) return false;

    const found = emit.back_of(emitter, named) orelse return true;
    if (emit.is_dot(emitter, found)) return false;
    return !walk.text_is(emitter.tokens[found].text(emitter.source), "!");
}

pub fn fields_joined(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (!emitter.policy.literal_joins) return false;
    if (emitter.policy.literal_width == 0) return false;
    if (emitter.depth == 0) return false;

    const frame = emitter.nest[emitter.depth - 1];
    if (frame.kind != .block_start) return false;
    if (!wide.valued_brace(emitter, frame.open)) return false;

    const close = closing_of(emitter, frame.open) orelse return false;
    const head = emit.ahead_of(emitter, frame.open) orelse return false;
    const last = fields_last(emitter, frame.open, close) orelse return false;

    if (position > close) return false;
    if (head > last) return false;

    const first, const level = line_lead(emitter, frame.open) orelse return false;

    if (!fields_parted(emitter, head, close)) return false;
    if (position <= head) return false;
    if (position >= close) return false;
    if (first > frame.open) return false;

    const fields = header_width(emitter, head, last) orelse return false;
    if (fields > emitter.policy.literal_width) return false;

    const width = header_width(emitter, first, close) orelse return false;
    return level * emitter.options.indent_width + width <= emitter.options.line_width;
}

fn fields_parted(emitter: *const Emitter, head: u32, close: u32) bool {
    assert(head < close);
    assert(close < emitter.count);

    const end = emit.back_of(emitter, close) orelse return false;
    if (end <= head) return false;

    const width = header_width(emitter, head, end) orelse return true;
    return width > emitter.policy.literal_width;
}

fn fields_last(emitter: *const Emitter, open: u32, close: u32) ?u32 {
    assert(open < close);
    assert(close < emitter.count);

    var last = emit.back_of(emitter, close) orelse return null;
    if (last <= open) return null;

    if (emitter.tokens[last].is_punctuation(.comma)) {
        last = emit.back_of(emitter, last) orelse return null;
    }

    const ranged = emit.ranges(emitter, last) and !wide.macro_argued(emitter);

    if (ranged) {
        last = emit.back_of(emitter, last) orelse return null;

        if (emitter.tokens[last].is_punctuation(.comma)) {
            last = emit.back_of(emitter, last) orelse return null;
        }
    }

    if (last <= open) return null;
    return last;
}

pub fn attribute_joined(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (!emitter.policy.attribute_joins) return false;
    if (emitter.policy.attribute_width == 0) return false;
    if (emitter.depth == 0) return false;

    const frame = emitter.nest[emitter.depth - 1];
    if (!frame.kind.eql(.{ .punctuation = .paren_open })) return false;

    const close = closing_of(emitter, frame.open) orelse return false;
    if (position > close) return false;

    const first, const level = line_lead(emitter, frame.open) orelse return false;
    if (first > frame.open) return false;
    if (!attribute_lead(emitter, first)) return false;

    const flat = flat_run(emitter, frame.open, close) orelse return false;
    if (flat > emitter.policy.attribute_width) return false;

    const width = header_width(emitter, first, close) orelse return false;
    return level * emitter.options.indent_width + width <= emitter.options.line_width;
}

pub fn attribute_broken(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.policy.attribute_width == 0) return false;
    if (emitter.depth == 0) return false;

    const frame = emitter.nest[emitter.depth - 1];
    if (!frame.kind.eql(.{ .punctuation = .paren_open })) return false;

    const close = closing_of(emitter, frame.open) orelse return false;

    if (position != close) {
        if (emit.back_of(emitter, position) != frame.open) return false;
    }

    const first, const level = line_lead(emitter, frame.open) orelse return false;
    if (first > frame.open) return false;
    if (!attribute_lead(emitter, first)) return false;
    if (!attribute_plain(emitter, frame.open, close)) return false;

    const width = header_width(emitter, first, close) orelse return false;
    return level * emitter.options.indent_width + width + 1 > emitter.options.line_width;
}

fn attribute_plain(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    for (open + 1..close) |index| {
        if (walk.is_open(emitter.tokens[index].kind)) return false;
    }

    return true;
}

fn attribute_lead(emitter: *const Emitter, first: u32) bool {
    assert(first < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    if (!walk.text_is(emitter.tokens[first].text(emitter.source), "#")) return false;

    var scan = first;

    for (0..brace.nest_depth_max) |_| {
        const next = emit.ahead_of(emitter, scan) orelse return false;
        const text = emitter.tokens[next].text(emitter.source);

        if (!worded(attribute_marks, text)) {
            return !line.word_is(emitter, next, emitter.policy.attribute_words);
        }

        scan = next;
    }

    return false;
}

pub fn arm_emptied(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < emitter.count);

    if (!emitter.policy.arm_empties) return false;
    if (emitter.tokens[position].kind != .block_end) return false;
    if (emitter.tokens[previous].kind != .block_start) return false;
    if (!armed_frame(emitter, previous)) return false;
    return empty_fits(emitter, position);
}

pub fn welded_level(emitter: *const Emitter, leading: u32) ?u32 {
    assert(leading < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.depth == 0) return null;

    const frame = emitter.nest[emitter.depth - 1];
    if (frame.kind != .block_start) return null;
    if (leading <= frame.open) return null;
    if (!emit.defined_branch(emitter, frame.open)) return null;

    const arrow = emit.back_of(emitter, frame.open) orelse return null;
    if (!walk.text_is(emitter.tokens[arrow].text(emitter.source), "=>")) return null;

    const inner = emit.ahead_of(emitter, frame.open) orelse return null;
    if (emitter.tokens[inner].kind != .block_start) return null;

    const from = emitter.tokens[frame.open].end();
    const to = emitter.tokens[inner].offset;
    if (body.parted_by(emitter, from, to) != 0) return null;
    if (inner >= leading) return null;
    return lead.leveled_at(emitter, frame.open);
}

pub fn arm_empty_level(emitter: *const Emitter, leading: u32) ?u32 {
    assert(leading < emitter.count);

    if (emitter.tokens[leading].kind != .block_end) return null;

    const open = emitter.brackets.open_of(leading) orelse return null;

    assert(open < leading);

    if (emit.ahead_of(emitter, open) != leading) return null;
    if (!armed_frame(emitter, open)) return null;

    const arrow = emit.back_of(emitter, open) orelse return null;
    const head = arm_head(emitter, arrow) orelse return null;

    return lead.leveled_at(emitter, head);
}

fn empty_fits(emitter: *const Emitter, close: u32) bool {
    assert(close < emitter.count);
    assert(emitter.line_first < emitter.count);

    const width = header_width(emitter, emitter.line_first, close) orelse return false;
    return emitter.printed * emitter.options.indent_width + width < emitter.options.line_width;
}

fn armed_frame(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    if (emitter.tokens[open].kind != .block_start) return false;
    return arm_brace(emitter, open);
}

fn arm_brace(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    const held = emit.back_of(emitter, open) orelse return false;

    assert(held < open);

    return walk.text_is(emitter.tokens[held].text(emitter.source), "=>");
}

fn arm_guarded(emitter: *const Emitter, head: u32, arrow: u32) bool {
    assert(head < arrow);
    assert(arrow < emitter.count);

    if (!body.parts_at(emitter, head, arrow)) return false;

    var depth: u32 = 0;
    var scan = head;

    for (0..define_scan_max) |_| {
        if (scan >= arrow) return false;

        const kind = emitter.tokens[scan].kind;

        if (walk.is_open(kind)) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            depth -|= 1;
        } else if (depth == 0) {
            if (walk.text_is(emitter.tokens[scan].text(emitter.source), "if")) return true;
        } else {}

        scan = emit.ahead_of(emitter, scan) orelse return false;
    }

    return true;
}

fn arm_called(emitter: *const Emitter, last: u32) bool {
    assert(last < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    if (!walk.is_close(emitter.tokens[last].kind)) return false;

    const open = emit.opened(emitter, last) orelse return false;
    const held = emit.back_of(emitter, open) orelse return false;

    return walk.text_is(emitter.tokens[held].text(emitter.source), "!");
}

fn arm_seated(emitter: *const Emitter, head: u32, arrow: u32, first: u32, last: u32) bool {
    assert(head < arrow);
    assert(first <= last);

    const start = arm_start(emitter, head, arrow);
    const pattern = header_width(emitter, start, arrow) orelse return false;
    const bodied = header_width(emitter, first, last) orelse return false;
    const seat = line.level_at(emitter, start) orelse emitter.printed;
    const under = seat * emitter.options.indent_width;
    const width = emitter.options.line_width;
    if (under + pattern + bodied + arm_margin <= width) return false;
    return under + emitter.options.indent_width + bodied + join_margin <= width;
}

fn arm_fits(emitter: *const Emitter, head: u32, arrow: u32, first: u32, stop: u32) bool {
    assert(head < arrow);
    assert(first <= stop);

    const start = arm_start(emitter, head, arrow);
    const pattern = header_width(emitter, start, arrow) orelse return false;
    const bodied = header_width(emitter, first, stop) orelse return false;
    const level = line.level_at(emitter, start) orelse emitter.printed;
    const width = pattern + bodied + arm_margin + wide.chain_tried(emitter, first, stop);

    return level * emitter.options.indent_width + width <= emitter.options.line_width;
}

fn arm_start(emitter: *const Emitter, head: u32, arrow: u32) u32 {
    assert(head < arrow);
    assert(arrow < emitter.count);

    const found, _ = line_lead(emitter, arrow) orelse return head;
    if (found > head) return found;
    return head;
}

fn arm_chain(emitter: *const Emitter, first: u32, last: u32) ?u32 {
    assert(first <= last);
    assert(last < emitter.count);

    var depth: u32 = 0;
    var scan = first;

    for (0..define_scan_max) |_| {
        if (scan >= last) return null;

        const kind = emitter.tokens[scan].kind;

        if (walk.is_open(kind)) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            depth -|= 1;
        } else if (depth == 0) {
            if (dot_linked(emitter, scan)) return arm_chained(emitter, first, scan);
        } else {}

        scan = emit.ahead_of(emitter, scan) orelse return null;
    }

    return null;
}

fn arm_chained(emitter: *const Emitter, first: u32, scan: u32) ?u32 {
    assert(first <= scan);
    assert(scan < emitter.count);

    if (scan <= first) return null;
    if (chained_flat(emitter, scan)) return null;
    assert(scan - 1 <= emitter.count);

    return scan - 1;
}

fn arm_open(emitter: *const Emitter, first: u32, last: u32) ?u32 {
    assert(first <= last);
    assert(last < emitter.count);

    var scan = first;

    for (0..define_scan_max) |_| {
        if (scan >= last) return null;

        const next = emit.ahead_of(emitter, scan) orelse return null;
        const opens = walk.is_open(emitter.tokens[scan].kind);

        const extended = opens and body.parts_at(emitter, scan, next) and
            arm_extends(emitter, scan, last);

        if (extended) return scan;

        scan = next;
    }

    return null;
}

pub fn arm_extends(emitter: *const Emitter, open: u32, last: u32) bool {
    assert(open < emitter.count);
    assert(last < emitter.count);

    var depth: u32 = 0;
    var scan = open;

    for (0..define_scan_max) |_| {
        const kind = emitter.tokens[scan].kind;

        if (walk.is_open(kind)) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            depth -|= 1;

            if (depth == 0) return arm_tail(emitter, scan, last);
        } else {}

        if (scan >= last) return false;

        scan = emit.ahead_of(emitter, scan) orelse return false;
    }

    return false;
}

fn arm_tail(emitter: *const Emitter, close: u32, last: u32) bool {
    assert(close < emitter.count);
    assert(last < emitter.count);

    var scan = close;

    for (0..define_scan_max) |_| {
        if (scan >= last) return scan == last;

        scan = emit.ahead_of(emitter, scan) orelse return false;

        const kind = emitter.tokens[scan].kind;
        const asked = walk.text_is(emitter.tokens[scan].text(emitter.source), "?");
        const tail = walk.is_close(kind) or asked;
        if (!tail) return false;
    }

    return false;
}

fn arm_head(emitter: *const Emitter, arrow: u32) ?u32 {
    assert(arrow < emitter.count);

    var depth: u32 = 0;
    var scan = arrow;

    for (0..define_scan_max) |_| {
        const held = emit.back_of(emitter, scan) orelse return null;
        const kind = emitter.tokens[held].kind;

        assert(held < scan);

        if (walk.is_close(kind)) {
            const block = depth == 0 and kind == .block_end;

            if (block) {
                const open = emit.opened(emitter, held) orelse return null;
                if (arm_brace(emitter, open)) return scan;

                scan = open;

                continue;
            }

            depth += 1;
        } else if (walk.is_open(kind)) {
            if (depth == 0) return scan;

            depth -= 1;
        } else if (depth == 0) {
            if (arm_separated(kind)) return scan;
        } else {}

        scan = held;
    }

    return null;
}

fn arm_separated(kind: Token.Kind) bool {
    if (kind == .comment) return false;

    const result = kind.eql(.{ .punctuation = .comma }) or kind.eql(.{ .punctuation = .semicolon });

    if (result) assert(kind != .comment);
    if (kind == .identifier) assert(!result);

    return result;
}

pub fn item_joined(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.policy.item_words.len == 0) return false;

    const first, const level = line_lead(emitter, position) orelse return false;
    const top = emitter.depth == 0;
    const braced = top or emitter.nest[emitter.depth - 1].kind == .block_start;
    if (!braced) return false;
    if (!line.word_is(emitter, first, emitter.policy.item_words)) return false;
    if (!item_headed(emitter, first)) return false;

    const block = item_brace(emitter, first) orelse return false;
    if (position > block) return false;

    const width = header_width(emitter, first, block) orelse return false;
    return level * emitter.options.indent_width + width <= emitter.options.line_width;
}

fn item_headed(emitter: *const Emitter, first: u32) bool {
    assert(first < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    if (angle_head(emitter, first) != null) return false;

    const held = emit.back_of(emitter, first) orelse return true;
    const token = emitter.tokens[held];
    if (token.kind == .block_start) return true;
    if (token.kind == .block_end) return true;
    if (token.is_punctuation(.bracket_close)) return true;
    if (token.is_punctuation(.semicolon)) return true;
    return line.word_is(emitter, held, item_heads);
}

fn item_brace(emitter: *const Emitter, first: u32) ?u32 {
    assert(first < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    var depth: u32 = 0;
    var scan = first;

    for (0..define_scan_max) |_| {
        const kind = emitter.tokens[scan].kind;

        if (kind == .block_start) {
            if (depth == 0) return scan;
        }

        if (walk.is_open(kind)) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            depth -|= 1;
        } else if (depth == 0) {
            if (item_brace_stopped(emitter, scan)) return null;
        } else {}

        scan = emit.ahead_of(emitter, scan) orelse return null;
    }

    return null;
}

fn item_brace_stopped(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    const token = emitter.tokens[position];
    if (token.kind == .comment) return true;
    if (line.word_is(emitter, position, emitter.policy.clause_words)) return true;
    if (token.is_punctuation(.semicolon)) return true;
    if (!token.is_punctuation(.comma)) return false;
    return angle_head(emitter, position) == null;
}

pub fn listed_blank(emitter: *const Emitter) bool {
    assert(emitter.depth <= brace.nest_depth_max);

    if (!emitter.policy.list_blanks) return false;
    if (emitter.depth == 0) return false;

    const frame = emitter.nest[emitter.depth - 1];
    const kind = frame.kind;

    assert(emitter.policy.list_blanks);

    if (kind.eql(.{ .punctuation = .paren_open })) {
        if (header.params_blanked(emitter, frame.open)) return false;
    }

    return kind.eql(.{ .punctuation = .bracket_open }) or kind.eql(.{ .punctuation = .paren_open });
}

pub fn joins_a_break(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < emitter.count);

    if (flat_joined(emitter, position)) return true;
    if (header_joined(emitter, position, previous)) return true;
    if (arm_opened(emitter, position, previous)) return true;
    if (chain_flat(emitter, position, previous)) return true;
    if (hug_joined(emitter, position)) return true;
    if (sole_joined(emitter, position)) return true;
    if (macro_joined(emitter, position)) return true;
    if (mixed_joined(emitter, position)) return true;
    if (attribute_joined(emitter, position)) return true;
    return arm_emptied(emitter, position, previous);
}

pub fn signature_joined(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < emitter.count);

    if (emitter.policy.define_words.len == 0) return false;
    if (emitter.tokens[position].kind != .block_start) return false;
    if (emitter.tokens[previous].kind == .comment) return false;

    const head = body_signature(emitter, previous) orelse return false;
    const indent = emitter.options.indent_width;
    var item: u32 = 0;

    if (emitter.line_first > head) {
        const level = lead.leveled_at(emitter, head) orelse emitter.printed;

        item = level * indent;
    }

    const width = header_width(emitter, emitter.line_first, position) orelse return false;
    return item + emitter.printed * indent + width <= emitter.options.line_width;
}

pub fn body_signature(emitter: *const Emitter, last: u32) ?u32 {
    assert(last < emitter.count);
    assert(emitter.policy.define_words.len > 0);

    var scan = last;

    for (0..define_scan_max) |_| {
        const token = emitter.tokens[scan];
        if (token.kind == .block_end) return null;
        if (token.kind == .block_start) return null;
        if (worded(signature_stops, token.text(emitter.source))) return null;

        if (walk.is_close(token.kind)) {
            scan = emitter.brackets.open_of(scan) orelse return null;
        } else if (line.word_is(emitter, scan, emitter.policy.define_words)) {
            return scan;
        } else {}

        scan = emit.back_of(emitter, scan) orelse return null;
    }

    return null;
}

pub fn joined_dot(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < emitter.count);

    if (!emit.is_dot(emitter, position)) return false;
    if (emit.ranges(emitter, position)) return false;
    if (chain_hugged(emitter, position)) return true;
    if (root_joined(emitter, position, previous)) return true;
    if (span.chain_flatted(emitter, position)) return true;
    return chain_flat(emitter, position, previous);
}

pub fn called_gap(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < emitter.count);

    if (!emitter.policy.chain_simples) return false;
    if (!emitter.tokens[position].is_punctuation(.paren_open)) return false;

    const held = emitter.tokens[previous];

    const closed = held.kind == .block_end or held.is_punctuation(.bracket_close) or
        held.is_punctuation(.paren_close);

    if (!closed) return false;

    const open = emitter.brackets.open_of(previous) orelse return false;
    if (emit.bodied(emitter, open)) return false;

    const word = emit.word_before(emitter, open) orelse return true;
    return !line.word_is(emitter, word, emitter.policy.header_words);
}

pub fn closing_of(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);

    const token = emitter.tokens[position];
    if (walk.is_open(token.kind)) return emitter.brackets.close_of(position);
    if (walk.substituting(emitter.source, token)) return emitter.brackets.close_of(position);

    assert(token.kind != .block_start);

    return null;
}

pub fn macro_body(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    if (!emitter.policy.macro_spans) return null;

    const opened = emitter.tokens[position].kind;
    if (!walk.is_open(opened)) return null;

    if (opened == .block_start) {
        const next = emit.ahead_of(emitter, position) orelse return null;
        if (emitter.tokens[next].kind == .block_end) return null;
    }

    if (opened.eql(.{ .punctuation = .paren_open })) {
        if (emit.defined_branch(emitter, position)) return closing_of(emitter, position);
    }

    const previous = emitter.previous orelse return null;

    if (emitter.tokens[previous].kind == .identifier) {
        if (!emit.defining(emitter, previous)) return null;

        if (emitter.policy.macro_defines) {
            if (opened != .block_start) return closing_of(emitter, position);
        }

        if (emitter.policy.macro_bodies) {
            if (branched_def(emitter, position)) return null;
        }

        return emit.closing(emitter, position);
    }

    return macro_body_invoked(emitter, position, previous);
}

fn macro_body_invoked(emitter: *const Emitter, position: u32, previous: u32) ?u32 {
    assert(position < emitter.count);
    assert(previous < emitter.count);

    if (matcher_body(emitter, position, previous)) {
        const shut = closing_of(emitter, position) orelse return null;
        if (wide.streamed(emitter, position, shut)) return shut;
        if (unparsed(emitter, position, shut)) return shut;
        if (overrun(emitter, position, shut)) return shut;
        if (failed_macro(emitter, position, shut)) return shut;
        return null;
    }

    if (!emitter.tokens[previous].is_punctuation(.bang)) return null;

    const named = emit.word_before(emitter, previous) orelse return null;
    const kind = emitter.tokens[named].kind;
    const kinded = kind == .identifier or kind == .keyword;
    if (!kinded) return null;
    if (emitter.tokens[position].kind == .block_start) return emit.closing(emitter, position);

    const close = closing_of(emitter, position) orelse return null;
    if (wide.streamed(emitter, position, close)) return close;
    return null;
}

fn branched_def(emitter: *const Emitter, block: u32) bool {
    assert(block < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    const close = closing_of(emitter, block) orelse return false;
    var scan = block + 1;
    var branched = false;

    for (0..macro_branch_max) |_| {
        if (scan >= close) return branched;

        const end = branched_def_arm(emitter, scan) orelse return false;

        branched = true;
        scan = end + 1;

        if (emit.ahead_of(emitter, end)) |held| {
            if (emitter.tokens[held].is_punctuation(.semicolon)) scan = held + 1;
        }
    }

    return false;
}

fn branched_def_arm(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    if (!emitter.tokens[position].is_punctuation(.paren_open)) return null;

    const matcher = closing_of(emitter, position) orelse return null;
    const arrow = emit.ahead_of(emitter, matcher) orelse return null;
    if (!walk.text_is(emitter.tokens[arrow].text(emitter.source), "=>")) return null;

    const block = emit.ahead_of(emitter, arrow) orelse return null;
    if (emitter.tokens[block].kind != .block_start) return null;

    const end = closing_of(emitter, block) orelse return null;
    if (unparsed(emitter, block, end)) return null;
    if (overrun(emitter, block, end)) return null;
    if (wide.defined_stream(emitter, block, end)) return null;
    if (failed_macro(emitter, block, end)) return null;
    if (verbatim_overrun(emitter, position, block, end)) return null;
    return end;
}

fn failed_macro(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    for (open + 1..close) |index| {
        const scan: u32 = @intCast(index);
        if (!walk.is_open(emitter.tokens[scan].kind)) continue;

        const end = closing_of(emitter, scan) orelse continue;
        if (end >= close) continue;
        if (!failed_macro_invoked(emitter, scan)) continue;
        if (wide.unparsable(emitter, scan, end)) return true;
    }

    return false;
}

fn failed_macro_invoked(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    const bang = emit.word_before(emitter, position) orelse return false;

    assert(bang < position);

    return emitter.tokens[bang].is_punctuation(.bang);
}

fn verbatim_overrun(emitter: *const Emitter, matcher: u32, open: u32, close: u32) bool {
    assert(matcher < open);
    assert(open < close);

    const reach = line.column_of(emitter, matcher) + emitter.options.indent_width;
    const room = emitter.options.line_width -| reach;
    if (string_overrun(emitter, open, close, room)) return true;

    var scan = open + 1;

    while (scan < close) {
        const hash = scan;

        assert(hash > open);

        scan += 1;

        if (!walk.text_is(emitter.tokens[hash].text(emitter.source), "#")) continue;

        const bracket = emit.ahead_of(emitter, hash) orelse continue;
        if (!emitter.tokens[bracket].is_punctuation(.bracket_open)) continue;

        const shut = closing_of(emitter, bracket) orelse continue;
        if (shut >= close) continue;
        if (meta_item(emitter, bracket, shut)) continue;
        if (verbatim_overrun_lines(emitter, bracket, shut, room)) return true;

        scan = shut + 1;
    }

    return false;
}

fn verbatim_overrun_lines(emitter: *const Emitter, bracket: u32, shut: u32, room: u32) bool {
    assert(bracket < shut);
    assert(shut < emitter.count);

    const source = emitter.source;
    const to = emitter.tokens[shut].offset;
    var at: usize = emitter.tokens[bracket].end();

    while (std.mem.findScalarPos(u8, source[0..to], at, '\n')) |found| {
        const start = found + 1;
        const end = std.mem.findScalarPos(u8, source, start, '\n') orelse source.len;

        assert(start > at);

        if (walk.columns(source, @intCast(start), @intCast(end)) > room) return true;

        at = start;
    }

    return false;
}

fn string_overrun(emitter: *const Emitter, open: u32, close: u32, room: u32) bool {
    assert(open < close);
    assert(close < emitter.count);
    assert(room < std.math.maxInt(u32));

    for (open + 1..close) |index| {
        const token = emitter.tokens[index];
        if (token.kind != .string) continue;
        if (string_overrun_lines(emitter, token, room)) return true;
    }

    return false;
}

fn string_overrun_lines(emitter: *const Emitter, token: Token, room: u32) bool {
    assert(token.kind == .string);
    assert(token.end() <= emitter.source.len);

    const end = token.end();
    const text = emitter.source[0..end];
    var at: u32 = token.offset;

    while (std.mem.findScalarPos(u8, text, at, '\n')) |found| {
        const start: u32 = @intCast(found + 1);
        const held = std.mem.findScalarPos(u8, text, start, '\n');
        const stop: u32 = if (held) |newline| @intCast(newline) else end;

        assert(start > at);

        if (walk.columns(emitter.source, start, stop) > room) return true;

        at = start;
    }

    return false;
}

fn overrun(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    const source = emitter.source;

    for (open + 1..close) |index| {
        const token = emitter.tokens[index];
        const texted = token.kind == .comment or token.kind == .string;
        if (!texted) continue;

        const before = source[0..token.offset];
        const from = if (std.mem.findScalarLast(u8, before, '\n')) |held| held + 1 else 0;
        const to = std.mem.findScalarPos(u8, source, token.offset, '\n') orelse source.len;
        const width = walk.columns(source, @intCast(from), @intCast(to));
        if (width > emitter.options.line_width) return true;
    }

    return false;
}

fn unparsed(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    for (open + 1..close) |index| {
        if (unparsed_at(emitter, @intCast(index))) return true;
    }

    return false;
}

fn unparsed_at(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    const text = emitter.tokens[position].text(emitter.source);

    if (worded(macro_labels, text)) {
        if (emit.ahead_of(emitter, position)) |held| {
            if (walk.text_is(emitter.tokens[held].text(emitter.source), "$")) return true;
        }
    }

    const dollar = walk.text_is(text, "$");
    const hash = walk.text_is(text, "#");
    const marked = dollar or hash;
    if (!marked) return false;

    const next = emit.ahead_of(emitter, position) orelse return false;
    const kind = emitter.tokens[next].kind;
    const repeated = kind.eql(.{ .punctuation = .paren_open }) or kind == .block_start;

    if (dollar) {
        if (repeated) return true;
    }

    if (!hash) return false;
    return !kind.eql(.{ .punctuation = .bracket_open });
}

fn matcher_body(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < emitter.count);

    if (!emitter.policy.macro_defines) return false;
    if (emitter.tokens[position].kind != .block_start) return false;
    if (!emitter.tokens[previous].is_punctuation(.paren_close)) return false;

    const open = emit.opened(emitter, previous) orelse return false;
    const named = emit.word_before(emitter, open) orelse return false;
    if (emitter.tokens[named].kind != .identifier) return false;

    const held = emit.word_before(emitter, named) orelse return false;
    return walk.text_is(emitter.tokens[held].text(emitter.source), "macro");
}

pub fn attribute_span(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    if (!emitter.policy.attribute_spans) return null;
    if (!walk.text_is(emitter.tokens[position].text(emitter.source), "#")) return null;

    var open = emit.ahead_of(emitter, position) orelse return null;

    if (emitter.tokens[open].is_punctuation(.bang)) {
        open = emit.ahead_of(emitter, open) orelse return null;
    }

    if (!emitter.tokens[open].is_punctuation(.bracket_open)) return null;

    const close = closing_of(emitter, open) orelse return null;
    if (!meta_item(emitter, open, close)) return close;
    if (attribute_commented(emitter, open, close)) return close;
    return null;
}

fn attribute_commented(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    if (emit.ahead_of(emitter, open)) |held| {
        if (walk.text_is(emitter.tokens[held].text(emitter.source), "derive")) return false;
    }

    for (open + 1..close) |index| {
        if (emitter.tokens[index].kind == .comment) return true;
    }

    return false;
}

fn meta_item(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    for (open + 1..close) |index| {
        const scan: u32 = @intCast(index);
        const token = emitter.tokens[scan];
        if (!meta_item_held(emitter, token)) return false;
        if (!token.is_punctuation(.assign)) continue;
        if (!meta_item_valued(emitter, scan, close)) return false;
    }

    return true;
}

fn meta_item_held(emitter: *const Emitter, token: Token) bool {
    assert(token.end() <= emitter.source.len);
    assert(emitter.count <= emitter.tokens.len);

    switch (token.kind) {
        .identifier, .keyword, .newline => return true,
        .number, .string => return wide.meta_literal(token.kind, token.text(emitter.source)),
        .punctuation => |punctuation| switch (punctuation) {
            .assign, .comma, .paren_close, .paren_open => return true,
            else => {},
        },
        .block_end, .block_start, .comment => {},
    }

    return walk.text_is(token.text(emitter.source), "::");
}

fn meta_item_valued(emitter: *const Emitter, scan: u32, close: u32) bool {
    assert(scan < close);
    assert(close < emitter.count);

    const value = emit.ahead_of(emitter, scan) orelse return false;
    const token = emitter.tokens[value];
    const numeric = token.kind == .number or token.kind == .string;
    const literal = numeric or worded(boolean_words, token.text(emitter.source));
    if (!literal) return false;

    const found = emit.ahead_of(emitter, value) orelse return true;
    if (found == close) return true;

    const kind = emitter.tokens[found].kind;
    return kind.eql(.{ .punctuation = .comma }) or kind.eql(.{ .punctuation = .paren_close });
}

pub fn line_lead(emitter: *const Emitter, position: u32) ?struct { u32, u32 } {
    assert(position < emitter.count);

    const found = line.at(emitter, position) orelse return null;

    assert(found.start > 0);

    return .{ found.start - 1, found.level };
}

fn worded(words: []const []const u8, text: []const u8) bool {
    assert(words.len > 0);
    assert(text.len <= std.math.maxInt(u32));

    for (words) |word| {
        if (walk.text_eql(word, text)) return true;
    }

    return false;
}

pub fn lambda_room(emitter: *const Emitter, open: u32, brace_position: u32) u32 {
    assert(open < emitter.count);
    assert(brace_position < emitter.count);

    const width = emitter.policy.call_width;
    const bar = emit.back_of(emitter, brace_position) orelse return width;
    if (bar <= open) return width;

    const text = emitter.tokens[bar].text(emitter.source);

    if (walk.text_is(text, "||")) {
        assert(width -| (lambda_room_width + 1) < std.math.maxInt(u32));

        return width -| (lambda_room_width + 1);
    }

    if (!walk.text_is(text, "|")) return width;
    return lambda_room_scan(emitter, open, bar, width);
}

fn lambda_room_scan(emitter: *const Emitter, open: u32, bar: u32, width: u32) u32 {
    assert(open < bar);
    assert(bar < emitter.count);
    assert(width < std.math.maxInt(u32));

    var depth: u32 = 0;
    var measured = false;
    var scan = emit.back_of(emitter, bar);

    for (0..define_scan_max) |_| {
        const held = scan orelse return width;
        if (held <= open) return width;

        const token = emitter.tokens[held];

        if (walk.is_close(token.kind)) {
            depth += 1;
        } else if (walk.is_open(token.kind)) {
            depth -|= 1;
        } else if (depth == 0) {
            if (walk.text_is(token.text(emitter.source), "|")) {
                const room = width -| @as(u32, @intFromBool(measured)) * lambda_room_width;

                assert(room <= width);

                return room;
            }

            const separator = token.is_punctuation(.comma) or token.is_punctuation(.colon);

            if (separator) measured = true;
        } else {}

        scan = emit.back_of(emitter, held);
    }

    return width;
}

pub fn spread(emitter: *Emitter, position: u32, close: u32) error{Overflow}!void {
    assert(position <= close);
    assert(close < emitter.count);

    const started = emitter.tokens[position].kind == .block_start;
    const blocked = started or blocked_give(emitter, position, close);

    if (emit.macro_bracket(emitter, position)) {
        if (!blocked) return emit.restreamed(emitter, position, close);
    }

    if (!emitter.policy.macro_indents) return emit.spanned(emitter, position, close);
    if (emitter.options.tabs) return emit.spanned(emitter, position, close);
    if (!blocked) return emit.spanned(emitter, position, close);
    if (spelled(emitter, position, close)) return emit.spanned(emitter, position, close);

    if (stream.spilled(emitter.tokens, emitter.source, position, close)) {
        return emit.spanned(emitter, position, close);
    }

    const from = emitter.tokens[position].offset;
    const text = emitter.source[from..emitter.tokens[close].end()];

    emitter.previous = close;
    emitter.resume_at = close + 1;
    emitter.suppress_space = false;

    const base = emitter.printed * emitter.options.indent_width;
    const offset = emitter.arena.count();

    respread(emitter.arena, text, emitter.options.indent_width, base) catch |err| {
        emitter.arena.truncate(offset);

        return err;
    };

    assert(emitter.arena.count() >= offset);

    try emitter.document.push(.{ .verbatim_arena = .{
        .offset = offset,
        .length = emitter.arena.count() - offset,
    } });
}

pub fn cast_hugged(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.depth == 0) return false;
    if (!walk.text_is(emitter.tokens[open].text(emitter.source), "<")) return false;

    var held = emitter.nest[emitter.depth - 1];

    if (held.open > open) {
        if (emitter.depth > 1) held = emitter.nest[emitter.depth - 2];
    }

    if (!held.kind.eql(.{ .punctuation = .paren_open })) return false;
    if (!emitter.policy.chain_simples) return false;
    if (!list.calling(emitter, held.open)) return false;
    if (call.argument_end(emitter, open, held.close) != held.close) return false;

    const before = emit.back_of(emitter, open) orelse return false;

    if (before != held.open) {
        if (!emitter.tokens[before].is_punctuation(.comma)) return false;
    }

    return cast_hugged_close(emitter, open);
}

fn cast_hugged_close(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.policy.chain_simples);

    const close = angle_close(emitter, open) orelse return false;
    if (wrap.cast_open(emitter, close) != open) return false;

    const head = emit.ahead_of(emitter, open) orelse return false;
    if (head >= close) return false;

    const after = emit.ahead_of(emitter, close) orelse return false;

    const opened = emitter.tokens[after].kind == .block_start or
        emitter.tokens[after].is_punctuation(.bracket_open);

    if (!opened) return false;
    return hug_filled(emitter, after);
}

fn blocked_give(emitter: *const Emitter, position: u32, close: u32) bool {
    assert(position <= close);
    assert(close < emitter.count);

    const given = std.sort.binarySearch(u32, emitter.macros, position, blocked_give_order) orelse
        std.sort.binarySearch(u32, emitter.opaques, position, blocked_give_order);

    if (given == null) return false;

    const from = emitter.tokens[position].offset;
    const text = emitter.source[from..emitter.tokens[close].end()];
    const at = std.mem.findScalarLast(u8, text, '\n') orelse return false;
    const tail = std.mem.trim(u8, text[at + 1 ..], whitespace_ascii);
    const held = if (std.mem.endsWith(u8, tail, ";")) tail[0 .. tail.len - 1] else tail;
    if (held.len == 0) return false;

    for (held) |byte| {
        const closer = byte == '}' or byte == ')' or byte == ']';
        if (!closer) return false;
    }

    return true;
}

fn blocked_give_order(wanted: u32, held: u32) std.math.Order {
    assert(wanted < std.math.maxInt(u32));
    assert(held < std.math.maxInt(u32));

    return std.math.order(wanted, held);
}

pub fn statement_end(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    var depth: u32 = 0;
    var scan = position;

    for (0..define_scan_max) |_| {
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

fn parted_bracket(emitter: *const Emitter, from: u32, end: u32) ?u32 {
    assert(from < emitter.count);
    assert(end <= emitter.count);

    return point_of(evaluated(emitter, parted_frame(emitter, from, end)));
}

fn parted_frame(emitter: *const Emitter, from: u32, end: u32) Frame {
    assert(from < emitter.count);
    assert(end <= emitter.count);

    return .{ .parted = .{ .from = from, .end = end, .scan = from, .steps = 0, .phase = .scan } };
}

fn parted_step(emitter: *const Emitter, frame: *Parted, answer: ?Answer) Step {
    assert(frame.scan >= frame.from);
    assert(frame.steps <= define_scan_max);
    if (frame.phase == .scan) assert(answer == null);

    const scan = frame.scan;

    switch (frame.phase) {
        .scan => {},
        .literal => {
            if (verdict_of(answer)) return .{ .found = scan };

            frame.phase = .branched;

            return .{ .call = .{ .probe = wide.probe_of(.branched, scan, 0) } };
        },
        .branched => {
            if (verdict_of(answer)) return .{ .found = scan };

            assert(walk.is_open(emitter.tokens[scan].kind));

            frame.phase = .listed;

            return .{ .call = wide.listing_frame(emitter, scan) };
        },
        .listed => {
            if (point_of(answer) != null) return .{ .found = scan };

            frame.scan = emit.ahead_of(emitter, scan) orelse return .{ .found = null };
            frame.steps += 1;
        },
    }

    frame.phase = .scan;

    return parted_scan(emitter, frame);
}

fn parted_scan(emitter: *const Emitter, frame: *Parted) Step {
    assert(frame.phase == .scan);
    assert(frame.scan < emitter.count);

    while (frame.steps < define_scan_max) : (frame.steps += 1) {
        const scan = frame.scan;
        if (scan >= frame.end) return .{ .found = null };

        const kind = emitter.tokens[scan].kind;

        if (kind == .block_start) {
            frame.phase = .literal;

            return .{ .call = .{ .probe = wide.probe_of(.literal, scan, 0) } };
        }

        if (walk.is_open(kind)) {
            frame.phase = .listed;

            return .{ .call = wide.listing_frame(emitter, scan) };
        }

        frame.scan = emit.ahead_of(emitter, scan) orelse return .{ .found = null };
    }

    return .{ .found = null };
}

fn joined_width(emitter: *const Emitter, from: u32, end: u32, parted: u32) ?u32 {
    assert(from < emitter.count);
    assert(end < emitter.count);
    assert(parted < std.math.maxInt(u32));

    const first = emitter.tokens[from];
    var width = walk.columns(emitter.source, first.offset, first.end());
    var scan = from;

    for (0..define_scan_max) |_| {
        if (scan >= end) return width;

        const next = emit.ahead_of(emitter, scan) orelse return null;
        const token = emitter.tokens[next];
        const after = emitter.tokens[scan].end();
        const kept = joined_width_kept(emitter, scan, next, parted);

        if (token.kind == .comment) return null;
        if (kept) return null;
        if (std.mem.findScalar(u8, token.text(emitter.source), '\n') != null) return null;

        const gap: u32 = @intFromBool(token.offset > after);

        width += gap + walk.columns(emitter.source, token.offset, token.end());
        scan = next;
    }

    return null;
}

fn joined_width_kept(emitter: *const Emitter, scan: u32, next: u32, parted: u32) bool {
    assert(scan < next);
    assert(next < emitter.count);

    const token = emitter.tokens[next];
    const after = emitter.tokens[scan].end();
    if (body.parted_by(emitter, after, token.offset) == 0) return false;
    if (scan == parted) return false;
    if (walk.text_is(token.text(emitter.source), "else")) return false;
    if (chain_flat(emitter, next, scan)) return false;
    return !split.semicolon_joined(emitter, next, scan);
}

pub fn header_width(emitter: *const Emitter, from: u32, end: u32) ?u32 {
    assert(from < emitter.count);
    assert(end <= emitter.count);

    if (core.memo_found(emitter, .header_width, from, end)) |answer| {
        return if (answer == core.memo_none) null else answer;
    }

    const held = header_width_scanned(emitter, from, end);

    core.memo_store(emitter, .header_width, from, end, held orelse core.memo_none);

    return held;
}

fn header_width_scanned(emitter: *const Emitter, from: u32, end: u32) ?u32 {
    assert(from < emitter.count);
    assert(end < emitter.count);

    const first = emitter.tokens[from];
    var width = walk.columns(emitter.source, first.offset, first.end());
    var scan = from;

    for (0..define_scan_max) |_| {
        if (scan >= end) return width;

        const next = emit.ahead_of(emitter, scan) orelse return null;
        const token = emitter.tokens[next];
        const after = emitter.tokens[scan].end();

        assert(next > scan);

        if (token.kind == .comment) return null;
        if (std.mem.findScalar(u8, token.text(emitter.source), '\n') != null) return null;

        if (!wide.header_dropped(emitter, next)) {
            const glued = wide.flat_glued(emitter, next, scan);
            const gap: u32 = @intFromBool(token.offset > after and !glued);

            width += gap + walk.columns(emitter.source, token.offset, token.end());
        }

        scan = next;
    }

    return null;
}

fn parted_items(emitter: *const Emitter, open: u32, close: u32) u32 {
    assert(open < close);
    assert(close < emitter.count);

    var depth: u32 = 0;
    var items: u32 = 1;
    var last = open;
    var scan = open;

    for (0..define_scan_max) |_| {
        const next = emit.ahead_of(emitter, scan) orelse return 0;

        if (next >= close) {
            const ended = emitter.tokens[last].is_punctuation(.comma);
            const returned = items - @intFromBool(ended);

            assert(returned < std.math.maxInt(u32));

            return returned;
        }

        const kind = emitter.tokens[next].kind;

        if (walk.is_open(kind)) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            depth -|= 1;
        } else if (depth == 0) {
            if (kind.eql(.{ .punctuation = .comma })) items += 1;
        } else {}

        last = next;
        scan = next;
    }

    return 0;
}

fn hugged_brace(emitter: *const Emitter, open: u32, close: u32) ?u32 {
    assert(open < close);
    assert(close < emitter.count);

    var held = emit.back_of(emitter, close) orelse return null;

    if (emitter.tokens[held].is_punctuation(.comma)) {
        held = emit.back_of(emitter, held) orelse return null;
    }

    if (emitter.tokens[held].kind != .block_end) return null;
    if (held <= open) return null;
    return held;
}

fn chain_tail(emitter: *const Emitter, head: u32, last: u32) ?u32 {
    assert(head < emitter.count);
    assert(last < emitter.count);

    var depth: u32 = 0;
    var found: ?u32 = null;
    var scan = head;

    for (0..define_scan_max) |_| {
        if (scan > last) return found;

        const kind = emitter.tokens[scan].kind;

        if (walk.is_open(kind)) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            depth -|= 1;
        } else if (depth == 0) {
            if (chain_member(emitter, scan)) found = scan;
        } else {}

        scan = emit.ahead_of(emitter, scan) orelse return null;
    }

    return found;
}

fn chain_lasted(emitter: *const Emitter, open: u32, tail: u32, last: u32, under: u32) bool {
    assert(open < emitter.count);
    assert(tail <= last);
    assert(under < std.math.maxInt(u32));

    const close = closing_of(emitter, open) orelse return false;
    const first = emit.ahead_of(emitter, open) orelse return false;
    if (first >= close) return false;

    const held = emit.back_of(emitter, close) orelse return false;
    if (held < first) return false;

    const text = emitter.tokens[first].text(emitter.source);
    const barred = walk.text_is(text, "|") or walk.text_is(text, "move");
    if (!barred) return false;
    if (!capped_spans(emitter, first, held)) return false;

    const width = header_width(emitter, tail, last) orelse return false;
    return under + emitter.options.indent_width + width <= emitter.options.line_width;
}

fn chain_shown(
    emitter: *const Emitter,
    open: u32,
    links: u32,
    tail: u32,
    last: u32,
    under: u32,
) ?u32 {
    assert(open < emitter.count);
    assert(tail <= last);
    assert(links < std.math.maxInt(u32));
    assert(under < std.math.maxInt(u32));

    const block = hug_lambda(emitter, open) orelse return chain_soled(emitter, open, links);
    const barred = chain_shown_barred(emitter, open, block, tail, last, under);

    if (!wide.valued_brace(emitter, block)) {
        if (!barred) return null;
    }

    const close = closing_of(emitter, block) orelse return null;
    const head = emit.ahead_of(emitter, block) orelse return null;
    const ends = emit.back_of(emitter, close) orelse return null;
    if (ends < head) return null;
    if (barred) return block;

    const width = header_width(emitter, head, ends) orelse return block;
    if (width > emitter.policy.literal_width) return block;
    return null;
}

fn chain_shown_barred(
    emitter: *const Emitter,
    open: u32,
    block: u32,
    tail: u32,
    last: u32,
    under: u32,
) bool {
    assert(open < block);
    assert(tail <= last);

    if (!lambda_bar(emitter, block)) return false;
    assert(under < std.math.maxInt(u32));

    if (closing_of(emitter, open)) |close| {
        if (emit.ahead_of(emitter, close)) |next| {
            if (chain_member(emitter, next)) return false;
        }
    }

    return !chain_flattens(emitter, tail, last, under);
}

fn chain_flattens(emitter: *const Emitter, tail: u32, last: u32, under: u32) bool {
    assert(tail <= last);
    assert(last < emitter.count);
    assert(under < std.math.maxInt(u32));

    const measured = header_width(emitter, tail, last) orelse return false;
    var braces: u32 = 0;

    for (tail..last + 1) |index| {
        const scan: u32 = @intCast(index);

        if (emitter.tokens[scan].kind == .block_start) {
            if (lambda_bar(emitter, scan)) braces += 1;
        }
    }

    const width = measured -| 4 * braces;
    if (under + emitter.options.indent_width + width > emitter.options.line_width) return false;

    for (tail..last + 1) |index| {
        if (!chain_flattens_bracket(emitter, @intCast(index))) return false;
    }

    return true;
}

fn chain_flattens_bracket(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    const kind = emitter.tokens[position].kind;
    if (!walk.is_open(kind)) return true;
    if (kind == .block_start) return true;

    const close = closing_of(emitter, position) orelse return false;
    const first = emit.ahead_of(emitter, position) orelse return true;
    if (first >= close) return true;

    const end = emit.back_of(emitter, close) orelse return true;
    const text = emitter.tokens[first].text(emitter.source);
    const soled = walk.text_is(text, "|") or walk.text_is(text, "move");
    if (soled) return true;
    if (end < first) return true;

    const inside = flat_width(emitter, first, end) orelse return false;
    return inside <= emitter.policy.call_width;
}

fn chain_soled(emitter: *const Emitter, open: u32, links: u32) ?u32 {
    assert(open < emitter.count);
    assert(links <= define_scan_max);

    const close = closing_of(emitter, open) orelse return null;
    if (parted_items(emitter, open, close) != 1) return null;

    var held = emit.back_of(emitter, close) orelse return null;

    if (emitter.tokens[held].is_punctuation(.comma)) {
        held = emit.back_of(emitter, held) orelse return null;
    }

    if (!emitter.tokens[held].is_punctuation(.paren_close)) return null;

    const inner = emit.opened(emitter, held) orelse return null;
    if (inner <= open) return null;

    if (flat_run(emitter, inner, held)) |width| {
        if (width > emitter.policy.call_width) return inner;
    }

    const direct = hug_direct(emitter, open, inner);

    if (direct) {
        if (flat_run(emitter, open, close)) |width| {
            if (width > emitter.policy.call_width) return inner;
        }
    }

    if (links < 2) return null;
    if (!direct) return null;

    const first, const level = line_lead(emitter, open) orelse return null;
    const width = header_width(emitter, first, close) orelse return null;
    if (level * emitter.options.indent_width + width > emitter.options.line_width) return inner;
    return null;
}

fn hug_direct(emitter: *const Emitter, open: u32, inner: u32) bool {
    assert(open < inner);
    assert(inner < emitter.count);

    var scan = emit.ahead_of(emitter, open) orelse return false;

    for (0..define_scan_max) |_| {
        if (scan == inner) return true;

        const token = emitter.tokens[scan];
        const text = token.text(emitter.source);
        const joint = walk.text_is(text, "::") or walk.text_is(text, "!");

        if (token.kind != .identifier) {
            if (!joint) return false;
        }

        scan = emit.ahead_of(emitter, scan) orelse return false;
    }

    return false;
}

fn chain_call(emitter: *const Emitter, tail: u32, last: u32) ?u32 {
    assert(tail <= last);
    assert(last < emitter.count);

    var scan = tail;

    for (0..define_scan_max) |_| {
        const next = emit.ahead_of(emitter, scan) orelse return null;
        if (next > last) return null;

        const kind = emitter.tokens[next].kind;
        if (kind.eql(.{ .punctuation = .paren_open })) return next;
        if (walk.is_open(kind)) return null;
        if (walk.is_close(kind)) return null;

        scan = next;
    }

    return null;
}

fn spanned_width(emitter: *const Emitter, from: u32, to: u32) ?u32 {
    assert(from < emitter.count);
    assert(to < emitter.count);

    const first = emitter.tokens[from];
    var width = walk.columns(emitter.source, first.offset, first.end());
    var scan = from;

    for (0..define_scan_max) |_| {
        if (scan >= to) return width;

        const next = emit.ahead_of(emitter, scan) orelse return null;
        const token = emitter.tokens[next];
        const after = emitter.tokens[scan].end();
        const glued = emit.is_dot(emitter, next) or emit.is_dot(emitter, scan);

        if (token.kind == .comment) return null;
        if (std.mem.findScalar(u8, token.text(emitter.source), '\n') != null) return null;

        if (!glued) {
            if (body.parted_by(emitter, after, token.offset) > 0) return null;
        }

        const gap: u32 = @intFromBool(token.offset > after and !glued);

        width += gap + walk.columns(emitter.source, token.offset, token.end());
        scan = next;
    }

    return null;
}

fn spelled(emitter: *const Emitter, position: u32, close: u32) bool {
    assert(position <= close);
    assert(close < emitter.count);

    const previous = emitter.previous orelse return false;
    if (emitter.tokens[previous].kind != .identifier) return false;
    if (!emit.defining(emitter, previous)) return false;
    return unparsed(emitter, position, close);
}

fn chain_span(emitter: *const Emitter, dot: u32) struct { u32, u32, u32 } {
    assert(dot < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    var head = dot;
    var depth: u32 = 0;
    var scan = dot;

    for (0..define_scan_max) |_| {
        const found = emit.back_of(emitter, scan) orelse break;
        if (!chains_over(emitter, found, &depth, true)) break;

        head = found;
        scan = found;
    }

    var last = dot;

    depth = 0;
    scan = dot;

    for (0..define_scan_max) |_| {
        const found = emit.ahead_of(emitter, scan) orelse break;
        if (!chains_over(emitter, found, &depth, false)) break;

        last = found;
        scan = found;
    }

    assert(head <= dot);
    assert(last >= dot);

    return .{ head, last, chain_links(emitter, head, last) };
}

fn chain_member(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    if (!emit.is_dot(emitter, position)) return false;
    return !emit.ranges(emitter, position);
}

fn chain_kids(emitter: *const Emitter, head: u32, last: u32) u32 {
    assert(head < emitter.count);
    assert(last < emitter.count);

    var depth: u32 = 0;
    var links: u32 = 0;
    var scan = head;

    for (0..define_scan_max) |_| {
        if (scan > last) return links;

        const kind = emitter.tokens[scan].kind;

        if (walk.is_open(kind)) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            depth -|= 1;
        } else if (depth == 0) {
            if (chain_member(emitter, scan)) links += 1;
        } else {}

        scan = emit.ahead_of(emitter, scan) orelse return links;
    }

    return links;
}

fn chain_links(emitter: *const Emitter, head: u32, last: u32) u32 {
    assert(head < emitter.count);
    assert(last < emitter.count);

    var depth: u32 = 0;
    var links: u32 = 0;
    var scan = head;

    for (0..define_scan_max) |_| {
        if (scan > last) return links;

        const kind = emitter.tokens[scan].kind;

        if (walk.is_open(kind)) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            depth -|= 1;
        } else if (depth == 0) {
            const text = emitter.tokens[scan].text(emitter.source);
            const linked = chain_member(emitter, scan) or walk.text_is(text, "?");

            if (linked) links += 1;
        } else {}

        scan = emit.ahead_of(emitter, scan) orelse return links;
    }

    return links;
}

fn chains_over(emitter: *const Emitter, position: u32, depth: *u32, back: bool) bool {
    assert(position < emitter.count);
    assert(depth.* <= define_scan_max);

    const kind = emitter.tokens[position].kind;
    const block = kind == .block_start or kind == .block_end;
    const braced = back and block;
    const ended = braced and kind == .block_end;
    const started = braced and kind == .block_start;
    const opens = if (back) walk.is_close(kind) or ended else walk.is_open(kind);
    const closes = if (back) walk.is_open(kind) or started else walk.is_close(kind);
    const unbraced = depth.* == 0 and !braced and block;
    if (unbraced) return false;

    if (opens) {
        depth.* += 1;

        return true;
    }

    if (closes) {
        if (depth.* == 0) return false;

        depth.* -= 1;

        return true;
    }

    if (depth.* > 0) return kind != .comment;
    if (kind == .comment) return false;
    return chains_over_link(emitter, position);
}

fn chains_over_link(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    const token = emitter.tokens[position];
    const text = token.text(emitter.source);

    switch (token.kind) {
        .identifier, .number, .string => return true,
        .block_end, .block_start, .comment, .keyword, .newline, .punctuation => {},
    }

    if (emit.is_dot(emitter, position)) return true;
    if (chains_over_angled(text)) return true;
    if (line.word_is(emitter, position, emitter.policy.operand_words)) return true;
    if (worded(chain_marks, text)) return true;
    if (!token.is_punctuation(.comma)) return false;
    return angle_head(emitter, position) != null;
}

fn chains_over_angled(text: []const u8) bool {
    assert(text.len <= std.math.maxInt(u32));

    if (text.len == 0) return false;

    const angled = std.mem.allEqual(u8, text, '<') or std.mem.allEqual(u8, text, '>');

    if (angled) assert(text[0] == '<' or text[0] == '>');

    return angled;
}

fn letting(emitter: *const Emitter, head: u32, open: u32) bool {
    assert(head < emitter.count);
    assert(open < emitter.count);

    var depth: u32 = 0;
    var bound = false;
    var chained = false;
    var ampersand: u32 = 0;
    var scan = head;

    for (0..define_scan_max) |_| {
        if (scan >= open) return bound and chained;

        const text = emitter.tokens[scan].text(emitter.source);
        const kind = emitter.tokens[scan].kind;

        if (walk.is_open(kind)) {
            depth += 1;
            ampersand = 0;
        } else if (walk.is_close(kind)) {
            depth -|= 1;
            ampersand = 0;
        } else if (depth == 0) {
            ampersand = if (walk.text_is(text, "&")) ampersand + 1 else 0;
            bound = bound or walk.text_is(text, "let");
            chained = chained or walk.text_is(text, "&&") or ampersand > 1;
        } else {}

        scan = emit.ahead_of(emitter, scan) orelse return bound and chained;
    }

    return false;
}

fn looping(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    if (!walk.text_is(emitter.tokens[position].text(emitter.source), "for")) return true;

    const previous = emit.back_of(emitter, position) orelse return true;
    const kind = emitter.tokens[previous].kind;
    if (kind == .block_start) return true;
    if (kind == .block_end) return true;
    if (kind.eql(.{ .punctuation = .colon })) return true;
    return kind.eql(.{ .punctuation = .semicolon });
}

fn hug_block(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    const held = emit.back_of(emitter, open) orelse return true;
    const token = emitter.tokens[held];
    if (token.is_punctuation(.comma)) return true;
    if (token.is_punctuation(.paren_open)) return true;
    return worded(hug_blocks, token.text(emitter.source));
}

pub fn angle_hugged(emitter: *const Emitter, head: u32, close: u32) bool {
    assert(head <= close);
    assert(close < emitter.count);

    if (angle_hugged_comma(emitter, head, close)) return false;

    if (emitter.tokens[head].kind == .block_start) {
        if (emitter.brackets.close_of(head) == emit.back_of(emitter, close)) return true;
    }

    const members = angle_hugged_members(emitter, head, close);

    if (members.count == 1) {
        return angle_member_hugged(emitter, members.start, members.stop, members.voids);
    }

    if (members.count != 0) return false;
    return emit.ahead_of(emitter, head) == close;
}

fn angle_hugged_comma(emitter: *const Emitter, head: u32, close: u32) bool {
    assert(head <= close);
    assert(close < emitter.count);

    var nesting: u32 = 0;
    var walked = head;

    while (walked < close) {
        if (angle_hugged_skip(emitter, walked, close, false)) |end| {
            walked = end + 1;

            continue;
        }

        const kind = emitter.tokens[walked].kind;

        if (walk.is_open(kind)) {
            nesting += 1;
        } else if (walk.is_close(kind)) {
            nesting -|= 1;
        } else if (nesting == 0) {
            if (kind.eql(.{ .punctuation = .comma })) return true;
        } else {}

        walked += 1;
    }

    return false;
}

fn angle_hugged_skip(emitter: *const Emitter, scan: u32, close: u32, bounded: bool) ?u32 {
    assert(scan <= close);
    assert(close < emitter.count);

    if (tmpl.template_body(emitter, scan)) |end| {
        assert(end > scan);

        if (!bounded) return end;
        if (end < close) return end;
    }

    return member_angle_end(emitter, scan, close);
}

fn angle_hugged_members(emitter: *const Emitter, head: u32, close: u32) AngleMembers {
    assert(head <= close);
    assert(close < emitter.count);

    var members: AngleMembers = .{ .start = 0, .stop = 0, .count = 0, .voids = 0 };
    var depth: u32 = 0;
    var from = head;
    var scan = head;

    while (scan <= close) {
        if (angle_hugged_skip(emitter, scan, close, true)) |end| {
            scan = end + 1;

            continue;
        }

        const kind = emitter.tokens[scan].kind;
        const bar = angle_hugged_bar(emitter, scan, close, depth);

        if (walk.is_open(kind)) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            depth -|= 1;
        } else {}

        const ends = bar or scan == close;

        if (ends) {
            angle_hugged_member(emitter, &members, from, scan);
            from = scan + 1;
        }

        scan += 1;
    }

    return members;
}

fn angle_hugged_bar(emitter: *const Emitter, scan: u32, close: u32, depth: u32) bool {
    assert(scan <= close);
    assert(close < emitter.count);

    if (depth != 0) return false;
    if (scan >= close) return false;
    return walk.text_is(emitter.tokens[scan].text(emitter.source), "|");
}

fn angle_hugged_member(emitter: *const Emitter, members: *AngleMembers, from: u32, scan: u32) void {
    assert(scan < emitter.count);
    assert(from <= scan);

    if (from >= scan) return;

    if (angle_voided(emitter, from, scan)) {
        members.voids += 1;
    } else {
        members.start = from;
        members.stop = scan;
        members.count += 1;
    }
}

fn angle_member_hugged(emitter: *const Emitter, start: u32, stop: u32, voids: u32) bool {
    assert(start < stop);
    assert(stop < emitter.count);

    if (emitter.tokens[start].kind == .block_start) {
        return emitter.brackets.close_of(start) == emit.back_of(emitter, stop);
    }

    if (voids > 0) {
        if (generic_reference(emitter, start, stop)) return true;

        if (emit.ahead_of(emitter, start) == stop) {
            if (!angle_member_named(emitter, start)) return false;
        }
    }

    if (tmpl.template_body(emitter, start)) |end| {
        if (emit.ahead_of(emitter, end) == stop) return true;
    }

    var scan = start;

    while (scan < stop) : (scan += 1) {
        if (worded(angle_queries, emitter.tokens[scan].text(emitter.source))) return false;
    }

    scan = start;

    while (scan < stop) : (scan += 1) {
        if (!angle_member_plain(emitter, scan)) return false;
    }

    return true;
}

fn angle_member_named(emitter: *const Emitter, start: u32) bool {
    assert(start < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    const token = emitter.tokens[start];
    if (token.kind != .identifier) return false;
    return !worded(angle_primitives, token.text(emitter.source));
}

fn angle_member_plain(emitter: *const Emitter, scan: u32) bool {
    assert(scan < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    const kind = emitter.tokens[scan].kind;
    if (kind == .identifier) return true;
    if (kind == .keyword) return true;
    if (kind == .number) return true;
    if (kind == .string) return true;
    return emit.is_dot(emitter, scan);
}

fn member_angle_end(emitter: *const Emitter, position: u32, close: u32) ?u32 {
    assert(position <= close);
    assert(close < emitter.count);

    if (!walk.text_is(emitter.tokens[position].text(emitter.source), "<")) return null;

    const end = angle_close(emitter, position) orelse return null;

    assert(end > position);

    if (end >= close) return null;
    return end;
}

pub fn generic_reference(emitter: *const Emitter, start: u32, stop: u32) bool {
    assert(start < stop);
    assert(stop < emitter.count);

    var scan = start;

    while (scan < stop) {
        const token = emitter.tokens[scan];

        if (walk.text_is(token.text(emitter.source), "<")) {
            if (scan <= start) return false;

            const close = angle_close(emitter, scan) orelse return false;
            return emit.ahead_of(emitter, close) == stop;
        }

        if (token.kind != .identifier) {
            if (!emit.is_dot(emitter, scan)) return false;
        }

        scan = emit.ahead_of(emitter, scan) orelse return false;
    }

    return false;
}

fn angle_voided(emitter: *const Emitter, from: u32, to: u32) bool {
    assert(from < to);
    assert(to <= emitter.count);

    var scan = from;

    while (scan < to) : (scan += 1) {
        const token = emitter.tokens[scan];
        if (token.length == 0) continue;
        if (token.kind == .newline) continue;
        if (to != scan + 1) return false;
        return worded(angle_voids, token.text(emitter.source));
    }

    return true;
}

pub fn angle_return_wide(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    const paren = unite.angle_return_paren(emitter, open) orelse return false;
    const close = angle_close(emitter, open) orelse return false;
    var end = close;

    for (0..angle_tail_max) |_| {
        const held = emit.ahead_of(emitter, end) orelse break;
        const kind = emitter.tokens[held].kind;

        end = held;

        if (kind == .block_start) break;
        if (kind.eql(.{ .punctuation = .semicolon })) break;
    }

    const width = span.printed_columns(emitter, paren, end);
    return emitter.printed * emitter.options.indent_width + width > emitter.options.line_width;
}

fn angle_return_hugged(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    const close = unite.angle_return_paren(emitter, open) orelse return false;
    const paren = emitter.brackets.open_of(close) orelse return false;
    const shut = emit.back_of(emitter, close) orelse return false;

    if (!angle_return_thised(emitter, paren)) return false;
    if (emitter.tokens[shut].kind != .block_end) return false;
    return wide.element_count(emitter, paren, close) == 1;
}

fn angle_return_thised(emitter: *const Emitter, paren: u32) bool {
    assert(paren < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    const name = emit.ahead_of(emitter, paren) orelse return false;
    if (!walk.text_is(emitter.tokens[name].text(emitter.source), "this")) return false;

    const colon = emit.ahead_of(emitter, name) orelse return false;
    return emitter.tokens[colon].is_punctuation(.colon);
}

pub fn signature_brace(emitter: *const Emitter, params: u32) ?u32 {
    assert(params < emitter.count);

    var scan = closing_of(emitter, params) orelse return null;

    for (0..core.define_scan_max) |_| {
        scan = emit.ahead_of(emitter, scan) orelse return null;

        const token = emitter.tokens[scan];

        if (token.kind == .block_start) {
            if (!signature_brace_typed(emitter, scan)) return scan;

            scan = closing_of(emitter, scan) orelse return null;

            continue;
        }

        if (walk.is_open(token.kind)) {
            scan = closing_of(emitter, scan) orelse return null;

            continue;
        }

        if (token.is_punctuation(.semicolon)) return null;
    }

    return null;
}

fn signature_brace_typed(emitter: *const Emitter, scan: u32) bool {
    assert(scan < emitter.count);

    const held = emit.back_of(emitter, scan) orelse return false;
    const text = emitter.tokens[held].text(emitter.source);
    if (walk.text_is(text, ":")) return true;
    if (walk.text_is(text, "|")) return true;
    if (walk.text_is(text, "&")) return true;
    if (walk.text_is(text, ",")) return true;
    if (walk.text_is(text, "<")) return true;
    return walk.text_is(text, "=>");
}

fn hug_filled(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    const close = closing_of(emitter, open) orelse return false;
    return emit.ahead_of(emitter, open) != close;
}

pub fn paren_literal(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    if (!emitter.tokens[open].is_punctuation(.paren_open)) return false;
    if (list.calling(emitter, open)) return false;
    if (split.headed(emitter, open)) return false;

    const head = emit.ahead_of(emitter, open) orelse return false;
    return paren_literal_head(emitter, head, close);
}

fn paren_literal_head(emitter: *const Emitter, head: u32, close: u32) bool {
    assert(head < emitter.count);
    assert(close < emitter.count);

    const kind = emitter.tokens[head].kind;
    const opens = kind == .block_start or kind.eql(.{ .punctuation = .bracket_open });
    if (!opens) return false;

    const end = closing_of(emitter, head) orelse return false;
    return emit.ahead_of(emitter, end) == close;
}

fn paren_ternaried(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    var depth: u32 = 0;
    var scan = open + 1;

    while (scan < close) {
        if (tmpl.spanned_unit(emitter, scan)) |end| {
            scan = end + 1;

            continue;
        }

        const token = emitter.tokens[scan];

        if (walk.is_open(token.kind)) {
            depth += 1;
        } else if (walk.is_close(token.kind)) {
            depth -|= 1;
        } else if (depth == 0) {
            if (paren_ternaried_operand(emitter, token, scan)) |found| return found;
        } else {}

        scan += 1;
    }

    return false;
}

fn paren_ternaried_operand(emitter: *const Emitter, token: Token, scan: u32) ?bool {
    assert(scan < emitter.count);
    assert(token.length <= std.math.maxInt(u32) - token.offset);

    const text = token.text(emitter.source);
    const separates = token.is_punctuation(.comma) or token.is_punctuation(.semicolon);
    const departs = separates or walk.text_is(text, "=>");
    if (departs) return false;
    if (!walk.text_is(text, "?")) return null;
    if (tern.optional(emitter, scan)) return null;
    return true;
}
