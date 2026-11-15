const std = @import("std");
const assert = std.debug.assert;
const Token = @import("../../syntax/token.zig");
const body = @import("body.zig");
const brace = @import("../brace.zig");
const clause = @import("clause.zig");
const commenting = @import("comment.zig");
const core = @import("emitter.zig");
const emit = @import("emit.zig");
const line = @import("line.zig");
const list = @import("list.zig");
const semi = @import("semi.zig");
const split = @import("split.zig");
const tmpl = @import("tmpl.zig");
const walk = @import("../walk.zig");
const wide = @import("wide.zig");
const Emitter = core.Emitter;

pub const Statement = union(StatementKind) {
    block: Block,
    bodied: Bodied,
    braced: Braced,
    declares: Declares,
    headed: Headed,
    member: Member,
    scan: Scan,
    word: Word,
};

pub const StatementAnswer = union(enum) {
    head: ?u32,
    verdict: bool,
};

pub const StatementStep = union(enum) {
    call: Statement,
    done: StatementAnswer,
};

pub const StatementScratch = struct {
    stack: [statement_frame_max]Statement,
    origins: [statement_frame_max]Statement,
    tainted: [statement_frame_max]bool,
    memo: StatementMemo,
    cache: [statement_cache_count]StatementCached,
    cache_generation: u32,
    contextual: bool,
    evaluating: bool,
    free: [statement_cache_count]StatementFree,

    pub fn init(scratch: *StatementScratch) void {
        scratch.evaluating = false;
        scratch.contextual = false;
        scratch.memo.generation = 1;
        scratch.memo.count = 0;
        scratch.cache_generation = 1;

        for (&scratch.memo.slots) |*slot| slot.generation = 0;
        for (&scratch.cache) |*entry| entry.generation = 0;
        for (&scratch.free) |*entry| entry.generation = 0;

        assert(!scratch.evaluating);
        assert(scratch.memo.find(&.{ .declares = .{ .close = 0 } }) == null);
    }

    pub fn begin(scratch: *StatementScratch) void {
        assert(!scratch.evaluating);
        assert(scratch.cache_generation < std.math.maxInt(u32));

        scratch.cache_generation += 1;
    }

    fn cached(
        scratch: *const StatementScratch,
        root: *const Statement,
        context: StatementContext,
    ) ?StatementAnswer {
        assert(scratch.evaluating);
        assert(scratch.cache_generation > 0);
        assert(context.depth <= brace.nest_depth_max);

        const held = &scratch.cache[statement_cache_slot(root, context)];
        if (held.generation != scratch.cache_generation) return null;
        if (!std.meta.eql(held.context, context)) return null;
        if (!std.meta.eql(held.key, root.*)) return null;

        assert((held.answer == .head) == statement_found(root.*));

        return held.answer;
    }

    fn cache_store(
        scratch: *StatementScratch,
        root: Statement,
        context: StatementContext,
        answer: StatementAnswer,
    ) void {
        assert(scratch.evaluating);
        assert((answer == .head) == statement_found(root));
        assert(context.depth <= brace.nest_depth_max);

        scratch.cache[statement_cache_slot(&root, context)] = .{
            .key = root,
            .context = context,
            .answer = answer,
            .generation = scratch.cache_generation,
        };
    }

    fn free_cached(scratch: *const StatementScratch, root: *const Statement) ?StatementAnswer {
        assert(scratch.evaluating);
        assert(scratch.cache_generation > 0);

        const held = &scratch.free[statement_free_slot(root)];
        if (held.generation != scratch.cache_generation) return null;
        if (!std.meta.eql(held.key, root.*)) return null;

        assert((held.answer == .head) == statement_found(root.*));

        return held.answer;
    }

    fn free_store(scratch: *StatementScratch, root: Statement, answer: StatementAnswer) void {
        assert(scratch.evaluating);
        assert((answer == .head) == statement_found(root));

        scratch.free[statement_free_slot(&root)] = .{
            .key = root,
            .answer = answer,
            .generation = scratch.cache_generation,
        };
    }

    fn answered(
        scratch: *StatementScratch,
        child: *const Statement,
        context: StatementContext,
        parent: u32,
    ) ?StatementAnswer {
        assert(scratch.evaluating);
        assert(parent < statement_frame_max);
        assert(context.depth <= brace.nest_depth_max);

        if (scratch.free_cached(child)) |held| return held;

        const held = scratch.cached(child, context) orelse return null;

        scratch.tainted[parent] = true;

        return held;
    }

    fn memo_answered(
        scratch: *StatementScratch,
        child: *const Statement,
        context: StatementContext,
        parent: u32,
    ) ?StatementAnswer {
        assert(scratch.evaluating);
        assert(parent < statement_frame_max);
        assert(context.depth <= brace.nest_depth_max);

        if (scratch.memo.find(child)) |held| {
            scratch.tainted[parent] = true;

            return held;
        }

        return scratch.answered(child, context, parent);
    }

    fn stored(
        scratch: *StatementScratch,
        context: StatementContext,
        answer: StatementAnswer,
        height: u32,
    ) void {
        assert(scratch.evaluating);
        assert(height > 0);
        assert(height < statement_frame_max);
        assert(context.depth <= brace.nest_depth_max);
        assert((answer == .head) == statement_found(scratch.origins[height]));

        const key = scratch.origins[height];

        scratch.cache_store(key, context, answer);

        if (scratch.tainted[height]) {
            scratch.tainted[height - 1] = true;
        } else {
            scratch.free_store(key, answer);
        }
    }
};

pub const Bodied = struct {
    position: u32,
    before: u32,
};

pub const Braced = struct {
    close: u32,
    open: u32,
    phase: BracedPhase,
};

pub const Declares = struct {
    close: u32,
};

pub const Headed = struct {
    position: u32,
};

pub const Member = struct {
    word: u32,
    open: u32,
};

pub const Word = struct {
    position: u32,
    scan: u32,
    depth: u32,
    steps: u32,
    waiting: bool,
};

const Block = struct {
    close: u32,
    declared: bool,
    phase: BlockPhase,
};

const BlockPhase = enum {
    braced,
    declares,
    start,
};

const BracedPhase = enum {
    bodied,
    plain,
    start,
};

const Scan = struct {
    position: u32,
    scan: u32,
    held: u32,
    depth: u32,
    steps: u32,
    declared: bool,
    waiting: bool,
};

const StatementMemo = struct {
    slots: [statement_memo_slot_count]StatementSlot,
    generation: u32,
    count: u32,

    fn clear(memo: *StatementMemo) void {
        assert(memo.count <= statement_memo_max);
        assert(memo.generation < std.math.maxInt(u32));

        memo.generation += 1;
        memo.count = 0;
    }

    fn find(memo: *const StatementMemo, key: *const Statement) ?StatementAnswer {
        assert(memo.count <= statement_memo_max);

        var at = statement_hash(key) & statement_memo_slot_mask;

        for (0..statement_memo_slot_count) |_| {
            const slot = &memo.slots[at];
            if (slot.generation != memo.generation) return null;

            if (std.meta.eql(slot.key, key.*)) {
                assert((slot.answer == .head) == statement_found(key.*));

                return slot.answer;
            }

            at = (at + 1) & statement_memo_slot_mask;
        }

        unreachable;
    }

    fn insert(memo: *StatementMemo, key: Statement, answer: StatementAnswer) void {
        assert(memo.count <= statement_memo_max);
        assert((answer == .head) == statement_found(key));

        if (memo.count == statement_memo_max) return;

        assert(memo.find(&key) == null);

        var at = statement_hash(&key) & statement_memo_slot_mask;

        for (0..statement_memo_slot_count) |_| {
            const slot = &memo.slots[at];

            if (slot.generation != memo.generation) {
                slot.* = .{ .key = key, .answer = answer, .generation = memo.generation };
                memo.count += 1;

                return;
            }

            at = (at + 1) & statement_memo_slot_mask;
        }

        unreachable;
    }
};

const StatementSlot = struct {
    key: Statement,
    answer: StatementAnswer,
    generation: u32,
};

const StatementFree = struct {
    key: Statement,
    answer: StatementAnswer,
    generation: u32,
};

const StatementCached = struct {
    key: Statement,
    context: StatementContext,
    answer: StatementAnswer,
    generation: u32,
};

const StatementContext = struct {
    depth: u32,
    top: u32,
    typed: bool,
};

const StatementKind = enum {
    block,
    bodied,
    braced,
    declares,
    headed,
    member,
    scan,
    word,
};

const body_followers: []const []const u8 = &.{
    "as",
    "catch",
    "else",
    "finally",
    "in",
    "instanceof",
    "satisfies",
};

const infix_words: []const []const u8 = &.{ "as", "in", "instanceof", "of", "satisfies" };
const member_words: []const []const u8 = &.{ "class", "enum", "interface" };
const statement_level_frame_max: u32 = 6;
const statement_frame_max: u32 = statement_level_frame_max * (brace.nest_depth_max + 2);
const statement_cache_count: u32 = 1 << 12;
const top_none: u32 = std.math.maxInt(u32);
const statement_memo_max: u32 = 256;
const statement_memo_slot_count: u32 = statement_memo_max * 2;
const statement_memo_slot_mask: u32 = statement_memo_slot_count - 1;
const statement_plain_step_max: u32 = 1 << 12;
const statement_step_max: u32 = 1 << 20;

comptime {
    assert(std.math.isPowerOfTwo(statement_cache_count));
    assert(std.math.isPowerOfTwo(statement_memo_slot_count));
    assert(statement_memo_slot_count > statement_memo_max);
    assert(statement_frame_max > brace.nest_depth_max);
    assert(statement_step_max > statement_frame_max);
    assert(statement_plain_step_max < statement_step_max);
}

pub fn statement_head(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);

    if (core.memo_found(emitter, .statement_head, position, 0)) |answer| {
        return if (answer == core.memo_none) null else answer;
    }

    const answer = statement_evaluated(emitter, statement_scan_frame(emitter, position, true));
    const head = answer.head;

    if (head) |held| assert(held <= position);

    core.memo_store(emitter, .statement_head, position, 0, head orelse core.memo_none);

    return head;
}

pub fn statement_evaluated(emitter: *const Emitter, root: Statement) StatementAnswer {
    assert(emitter.count <= emitter.tokens.len);
    assert(root != .block);

    const scratch = emitter.statements;

    assert(!scratch.evaluating);

    scratch.evaluating = true;
    defer scratch.evaluating = false;

    const context = statement_context(emitter);

    if (scratch.free_cached(&root)) |held| return held;
    if (scratch.cached(&root, context)) |held| return held;

    const value = statement_run(scratch, emitter, root, context);

    scratch.cache_store(root, context, value);

    if (!scratch.tainted[0]) scratch.free_store(root, value);

    return value;
}

fn statement_context(emitter: *const Emitter) StatementContext {
    assert(emitter.depth <= brace.nest_depth_max);

    const top = if (emitter.depth > 0) emitter.nest[emitter.depth - 1].open else top_none;

    if (emitter.depth > 0) assert(top < emitter.count);

    return .{ .depth = emitter.depth, .top = top, .typed = emitter.typed };
}

fn statement_run(
    scratch: *StatementScratch,
    emitter: *const Emitter,
    root: Statement,
    context: StatementContext,
) StatementAnswer {
    assert(scratch.evaluating);
    assert(root != .block);
    assert(context.depth <= brace.nest_depth_max);

    const stack = &scratch.stack;
    const origins = &scratch.origins;
    var height: u32 = 1;
    var answer: ?StatementAnswer = null;

    stack[0] = root;
    origins[0] = root;
    scratch.tainted[0] = false;

    for (0..statement_plain_step_max) |_| {
        assert(height > 0);
        assert(height <= statement_frame_max);

        const frame = &stack[height - 1];

        scratch.contextual = false;

        const step = statement_step(emitter, frame, answer);

        if (scratch.contextual) scratch.tainted[height - 1] = true;

        switch (step) {
            .call => |child| {
                assert(statement_calls(frame.*, child));
                assert(height < statement_frame_max);

                answer = scratch.answered(&child, context, height - 1);

                if (answer == null) {
                    stack[height] = child;
                    origins[height] = child;
                    scratch.tainted[height] = false;
                    height += 1;
                }
            },
            .done => |value| {
                assert((value == .head) == statement_found(frame.*));

                height -= 1;

                if (height == 0) return value;

                scratch.stored(context, value, height);
                answer = value;
            },
        }
    }

    return statement_memoized(scratch, emitter, root, context);
}

fn statement_memoized(
    scratch: *StatementScratch,
    emitter: *const Emitter,
    root: Statement,
    context: StatementContext,
) StatementAnswer {
    assert(scratch.evaluating);
    assert(root != .block);
    assert(context.depth <= brace.nest_depth_max);

    const stack = &scratch.stack;
    const origins = &scratch.origins;
    const memo = &scratch.memo;
    var height: u32 = 1;
    var answer: ?StatementAnswer = null;

    memo.clear();
    stack[0] = root;
    origins[0] = root;
    scratch.tainted[0] = false;

    for (0..statement_step_max) |_| {
        assert(height > 0);
        assert(height <= statement_frame_max);

        const frame = &stack[height - 1];

        scratch.contextual = false;

        const step = statement_step(emitter, frame, answer);

        if (scratch.contextual) scratch.tainted[height - 1] = true;

        switch (step) {
            .call => |child| {
                assert(statement_calls(frame.*, child));
                assert(height < statement_frame_max);

                answer = scratch.memo_answered(&child, context, height - 1);

                if (answer == null) {
                    stack[height] = child;
                    origins[height] = child;
                    scratch.tainted[height] = false;
                    height += 1;
                }
            },
            .done => |value| {
                assert((value == .head) == statement_found(frame.*));

                height -= 1;

                if (height == 0) return value;

                memo.insert(origins[height], value);
                scratch.stored(context, value, height);
                answer = value;
            },
        }
    }

    scratch.tainted[0] = true;

    if (statement_found(root)) return .{ .head = null };
    return .{ .verdict = false };
}

pub fn statement_member_frame(emitter: *const Emitter, word: u32) Statement {
    assert(word < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    return .{ .member = .{ .word = word, .open = word } };
}

pub fn statement_scan_frame(emitter: *const Emitter, position: u32, declared: bool) Statement {
    assert(position < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    return .{ .scan = .{
        .position = position,
        .scan = position,
        .held = position,
        .depth = 0,
        .steps = 0,
        .declared = declared,
        .waiting = false,
    } };
}

pub fn statement_word_frame(emitter: *const Emitter, position: u32) Statement {
    assert(position < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    return .{ .word = .{
        .position = position,
        .scan = position,
        .depth = 0,
        .steps = 0,
        .waiting = false,
    } };
}

fn statement_step(
    emitter: *const Emitter,
    frame: *Statement,
    answer: ?StatementAnswer,
) StatementStep {
    assert(emitter.count <= emitter.tokens.len);
    assert(emitter.depth <= brace.nest_depth_max);
    if (answer) |held| assert(held != .head or held.head == null or held.head.? < emitter.count);

    return switch (frame.*) {
        .block => |*held| statement_block_step(emitter, held, answer),
        .bodied => |*held| body.bodied_brace_step(emitter, held, answer),
        .braced => |*held| semi.statement_braced_step(emitter, held, answer),
        .declares => |*held| semi.declares_a_body_step(emitter, held, answer),
        .headed => |*held| split.headed_step(emitter, held, answer),
        .member => |*held| list.member_worded_step(emitter, held, answer),
        .scan => |*held| statement_scan_step(emitter, held, answer),
        .word => |*held| body.declared_word_step(emitter, held, answer),
    };
}

fn statement_calls(parent: StatementKind, child: StatementKind) bool {
    assert(parent != child);

    if (child == .block) assert(parent == .scan);

    return switch (parent) {
        .block => child == .declares or child == .braced,
        .bodied => child == .word,
        .braced => child == .bodied or child == .scan,
        .declares => child == .scan,
        .headed => child == .member,
        .member => child == .scan,
        .scan => child == .block or child == .headed,
        .word => child == .member,
    };
}

fn statement_found(kind: StatementKind) bool {
    return kind == .scan or kind == .word;
}

fn statement_cache_slot(root: *const Statement, context: StatementContext) u32 {
    assert(context.depth <= brace.nest_depth_max);

    const mixed = statement_hash(root) ^ (context.depth *% 0x27D4_EB2F) ^
        (context.top *% 0x1656_67B1) ^ @intFromBool(context.typed);

    const slot = mixed & (statement_cache_count - 1);

    assert(slot < statement_cache_count);

    return slot;
}

fn statement_free_slot(root: *const Statement) u32 {
    const slot = statement_hash(root) & (statement_cache_count - 1);

    assert(slot < statement_cache_count);

    return slot;
}

fn statement_hash(key: *const Statement) u32 {
    const first: u32, const second: u32 = switch (key.*) {
        .block => |held| .{ held.close, @intFromBool(held.declared) },
        .bodied => |held| .{ held.position, held.before },
        .braced => |held| .{ held.close, held.open },
        .declares => |held| .{ held.close, 0 },
        .headed => |held| .{ held.position, 0 },
        .member => |held| .{ held.word, held.open },
        .scan => |held| .{ held.position, @intFromBool(held.declared) },
        .word => |held| .{ held.position, held.scan },
    };

    const kind: u32 = @backingInt(std.meta.activeTag(key.*));
    const mixed = (first *% 0x9E37_79B1) ^ (second *% 0x85EB_CA77) ^ (kind *% 0xC2B2_AE3D);
    const hash = mixed ^ (mixed >> 15);

    assert(hash & statement_memo_slot_mask < statement_memo_slot_count);
    assert(kind < @typeInfo(StatementKind).@"enum".field_names.len);

    return hash;
}

fn statement_scan_step(
    emitter: *const Emitter,
    frame: *Scan,
    answer: ?StatementAnswer,
) StatementStep {
    assert(frame.position < emitter.count);
    assert(frame.steps <= core.define_scan_max);
    if (answer != null) assert(frame.waiting);

    if (answer) |closed| {
        assert(frame.waiting);
        assert(frame.depth == 0);

        frame.waiting = false;

        if (closed.verdict) return .{ .done = .{ .head = frame.scan } };

        frame.depth += 1;
        frame.scan = frame.held;
        frame.steps += 1;
    }

    while (frame.steps < core.define_scan_max) : (frame.steps += 1) {
        if (statement_scan_token(emitter, frame)) |step| return step;
    }

    return .{ .done = .{ .head = null } };
}

fn statement_scan_token(emitter: *const Emitter, frame: *Scan) ?StatementStep {
    assert(!frame.waiting);
    assert(frame.scan <= frame.position);

    const found: StatementStep = .{ .done = .{ .head = frame.scan } };
    const held = emit.back_of(emitter, frame.scan) orelse return found;
    const token = emitter.tokens[held];
    const opened = walk.substituting(emitter.source, token);
    const closes = !opened and walk.is_close(token.kind);
    const opens = opened or walk.is_open(token.kind);

    assert(held < frame.scan);

    if (closes) {
        if (frame.depth == 0) {
            if (statement_scan_closed(emitter, held, frame.declared)) |child| {
                frame.held = held;
                frame.waiting = true;

                return .{ .call = child };
            }
        }

        frame.depth += 1;
    } else if (opens) {
        if (frame.depth == 0) return found;

        frame.depth -= 1;
    } else if (frame.depth == 0) {
        if (statement_scan_ended(emitter, held)) return found;
    } else {}

    frame.scan = held;

    return null;
}

fn statement_scan_closed(emitter: *const Emitter, held: u32, declared: bool) ?Statement {
    assert(held < emitter.count);

    const kind = emitter.tokens[held].kind;

    assert(walk.is_close(kind));

    if (kind == .block_end) {
        return .{ .block = .{ .close = held, .declared = declared, .phase = .start } };
    }

    if (!kind.eql(.{ .punctuation = .paren_close })) return null;

    const open = emit.opened(emitter, held) orelse return null;

    assert(open < held);

    return .{ .headed = .{ .position = open } };
}

fn statement_block_step(
    emitter: *const Emitter,
    frame: *Block,
    answer: ?StatementAnswer,
) StatementStep {
    assert(frame.close < emitter.count);
    assert(emitter.tokens[frame.close].kind == .block_end);
    if (answer != null) assert(frame.declared);

    const returned = answer orelse return statement_block_start(emitter, frame);

    assert(frame.declared);

    if (frame.phase == .braced) return .{ .done = returned };

    assert(frame.phase == .declares);

    if (returned.verdict) return .{ .done = returned };

    frame.phase = .braced;

    return .{ .call = .{ .braced = .{
        .close = frame.close,
        .open = frame.close,
        .phase = .start,
    } } };
}

fn statement_block_start(emitter: *const Emitter, frame: *Block) StatementStep {
    assert(frame.phase == .start);
    assert(frame.close < emitter.count);

    if (statement_scan_spanned(emitter, frame.close)) return .{ .done = .{ .verdict = false } };
    if (!wide.joins_a_value(emitter, frame.close)) return .{ .done = .{ .verdict = true } };
    if (!frame.declared) return .{ .done = .{ .verdict = false } };

    frame.phase = .declares;

    return .{ .call = .{ .declares = .{ .close = frame.close } } };
}

fn statement_scan_spanned(emitter: *const Emitter, held: u32) bool {
    assert(held < emitter.count);
    assert(emitter.tokens[held].kind == .block_end);

    const after = emit.ahead_of(emitter, held) orelse return false;
    if (emitter.tokens[after].kind != .string) return false;
    return tmpl.template_closes(emitter, held);
}

fn statement_scan_ended(emitter: *const Emitter, held: u32) bool {
    assert(held < emitter.count);

    const token = emitter.tokens[held];
    if (token.is_punctuation(.semicolon)) return true;
    if (!token.is_punctuation(.colon)) return false;
    return split.armed(emitter, held);
}

pub fn follows_a_brace(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < position);

    if (emitter.policy.follow_words.len == 0) return false;

    if (emitter.tokens[previous].kind != .block_end) {
        if (!commenting.else_trailed(emitter, position, previous)) return false;
    }

    if (!line.word_is(emitter, position, emitter.policy.follow_words)) return false;
    return clause.follows_its_block(emitter, position);
}

pub fn bodied(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < position);

    if (!emitter.policy.body_parts) return false;
    if (!inside_a_body(emitter)) return false;

    const kind = emitter.tokens[position].kind;
    const held = emitter.tokens[previous].kind;

    if (emitter.depth > 0) {
        if (held == .block_start) return true;
        if (kind == .block_end) return true;
    }

    const membered = bodied_membered(emitter, position, held);

    const followed = held == .block_end and
        line.word_is(emitter, position, &.{"else"}) and
        !clause.follows_its_block(emitter, position);

    const ended = held.eql(.{ .punctuation = .semicolon }) or
        list.membered(emitter, previous) or
        membered or
        followed or
        bodied_closed(emitter, position, previous, held);

    if (!ended) return false;
    return !rides_a_line(emitter, position, previous);
}

fn bodied_membered(emitter: *const Emitter, position: u32, held: Token.Kind) bool {
    assert(position < emitter.count);
    assert(emitter.policy.body_parts);

    if (held != .block_end) return false;
    if (!emitter.closed.bodied) return false;
    if (emit.roled(emitter, emitter.closed.open, brace.role_type)) return false;
    if (emitter.depth == 0) return false;

    const frame = line.frame(emitter);
    if (frame.kind != .block_start) return false;

    const named = switch (emitter.tokens[position].kind) {
        .identifier, .keyword, .string => true,
        else => false,
    };

    const text = emitter.tokens[position].text(emitter.source);

    const marked = walk.text_is(text, "[") or walk.text_is(text, "#") or
        walk.text_is(text, "@") or walk.text_is(text, "*");

    if (!named) {
        if (!marked) return false;
    }

    return body.declared(emitter, frame.open);
}

fn bodied_closed(emitter: *const Emitter, position: u32, previous: u32, held: Token.Kind) bool {
    assert(previous < position);
    assert(emitter.policy.body_parts);

    if (held != .block_end) return false;

    const parted = body.parts(emitter, emitter.closed.open) or
        semi.statement_braced(emitter, previous) or
        semi.declares_a_body(emitter, previous);

    if (!parted) return false;
    if (opens_a_statement(emitter, position)) return true;
    return statement_opened(emitter, position, previous);
}

pub fn member_bodied(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    if (emitter.tokens[open].kind != .block_start) return false;

    const word = body.declared_word(emitter, open) orelse return false;

    assert(word < open);

    return line.word_is(emitter, word, member_words);
}

pub fn statement_ended(emitter: *const Emitter, held: u32) bool {
    assert(held < emitter.count);

    if (clause.header_closed(emitter, held)) return true;
    if (!emitter.policy.clause_lines) return false;
    if (emitter.tokens[held].kind != .block_end) return false;
    if (semi.declares_a_body(emitter, held)) return true;
    return semi.statement_braced(emitter, held);
}

pub fn block_stated(emitter: *const Emitter, before: u32) bool {
    assert(before < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    if (!emitter.policy.clause_lines) return false;

    const result = switch (emitter.tokens[before].kind) {
        .punctuation => |punctuation| block_stated_mark(emitter, before, punctuation),
        .block_start => body.bodied_brace(emitter, before),
        .block_end => block_stated_end(emitter, before),
        .comment, .identifier, .keyword, .newline, .number, .string => false,
    };

    return result;
}

fn block_stated_mark(emitter: *const Emitter, before: u32, punctuation: Token.Punctuation) bool {
    assert(before < emitter.count);
    assert(emitter.tokens[before].kind == .punctuation);

    if (punctuation == .semicolon) return true;
    if (punctuation == .colon) return split.armed(emitter, before);
    return false;
}

fn block_stated_end(emitter: *const Emitter, before: u32) bool {
    assert(before < emitter.count);
    assert(emitter.tokens[before].kind == .block_end);

    if (semi.declares_a_body(emitter, before)) return true;
    return semi.statement_braced(emitter, before);
}

pub fn statement_signed(emitter: *const Emitter, position: u32, held: u32) bool {
    assert(position < emitter.count);
    assert(held < emitter.count);

    const text = emitter.tokens[position].text(emitter.source);
    const signed = walk.text_is(text, "+") or walk.text_is(text, "-");
    if (!signed) return false;
    return statement_ended(emitter, held);
}

fn statement_opened(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < emitter.count);

    if (!follows_a_body(emitter, position)) return false;
    if (semi.declares_a_body(emitter, previous)) return true;
    return semi.statement_braced(emitter, previous);
}

fn follows_a_body(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    const text = emitter.tokens[position].text(emitter.source);
    if (walk.text_is(text, "while")) return !clause.follows_its_block(emitter, position);

    for (body_followers) |word| {
        if (walk.text_eql(word, text)) return false;
    }

    return true;
}

fn opens_a_statement(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    if (!follows_a_body(emitter, position)) return false;

    const kind = emitter.tokens[position].kind;
    if (kind == .block_start) return true;
    if (kind == .identifier) return true;
    return kind == .keyword;
}

fn rides_a_line(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < emitter.count);

    if (emitter.tokens[position].kind != .comment) return false;
    return !body.parts_at(emitter, previous, position);
}

pub fn header_closed(emitter: *const Emitter, close: u32, after: u32) bool {
    assert(close < after);
    assert(after < emitter.count);

    if (!emitter.policy.chain_simples) return false;
    if (!emitter.tokens[close].is_punctuation(.paren_close)) return false;

    if (emitter.brackets.open_of(close)) |open| {
        if (split.headed(emitter, open)) return true;
    }

    const token = emitter.tokens[after];
    const worded = token.kind == .identifier or token.kind == .keyword;
    const literal = token.kind == .number or token.kind == .string;
    if (!worded) return literal;
    return !line.word_is(emitter, after, infix_words);
}

pub fn inside_a_body(emitter: *const Emitter) bool {
    assert(emitter.depth <= brace.nest_depth_max);
    assert(emitter.count <= emitter.tokens.len);

    if (emitter.depth == 0) return true;
    return line.frame(emitter).bodied;
}
