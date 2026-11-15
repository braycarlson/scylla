const std = @import("std");
const assert = std.debug.assert;
const bind = @import("bind.zig");
const brace = @import("../brace.zig");
const core = @import("emitter.zig");
const edge = @import("edge.zig");
const emit = @import("emit.zig");
const join = @import("join.zig");
const line = @import("line.zig");
const split = @import("split.zig");
const tmpl = @import("tmpl.zig");
const unite = @import("unite.zig");
const walk = @import("../walk.zig");
const Emitter = core.Emitter;
const declare_named_heads: []const []const u8 = &.{ "enum", "interface", "module", "namespace" };
const semi_heads: []const []const u8 = &.{ "else", "finally" };
const semi_switches: []const []const u8 = &.{ "catch", "switch" };

const brace_heads: []const []const u8 = &.{
    "catch",
    "do",
    "else",
    "finally",
    "for",
    "if",
    "switch",
    "try",
    "while",
};

const declare_prefixes: []const []const u8 = &.{
    "abstract",
    "async",
    "declare",
    "default",
    "export",
};

pub fn empty_statement(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    if (!emitter.policy.empty_semis) return false;
    if (!emitter.tokens[position].is_punctuation(.semicolon)) return false;

    if (line.statement_level(emitter)) {
        if (empty_statement_coded(emitter)) return true;
    }

    if (classed_member(emitter)) return true;

    const close = emitter.previous orelse return false;
    if (emitter.tokens[close].kind != .block_end) return false;
    if (declares_a_body(emitter, close)) return true;

    const open = emitter.brackets.open_of(close) orelse return false;
    const before = emit.word_before(emitter, open) orelse return false;
    if (line.word_is(emitter, before, semi_heads)) return true;
    if (!emitter.tokens[before].is_punctuation(.paren_close)) return false;

    const paren = emitter.brackets.open_of(before) orelse return false;
    if (split.headed(emitter, paren)) return true;

    const held = emit.word_before(emitter, paren) orelse return false;
    return line.word_is(emitter, held, semi_switches);
}

fn empty_statement_coded(emitter: *const Emitter) bool {
    assert(emitter.count <= emitter.tokens.len);
    assert(emitter.depth <= brace.nest_depth_max);

    const held = line.coded(emitter) orelse return true;
    const kind = emitter.tokens[held].kind;
    if (kind == .block_start) return true;
    if (kind.eql(.{ .punctuation = .colon })) return empty_statement_cased(emitter, held);
    return kind.eql(.{ .punctuation = .semicolon });
}

fn empty_statement_cased(emitter: *const Emitter, colon: u32) bool {
    assert(colon < emitter.count);
    assert(emitter.tokens[colon].is_punctuation(.colon));

    if (emitter.depth == 0) return false;
    return bind.case_label(emitter, colon, line.frame(emitter).open);
}

fn classed_member(emitter: *const Emitter) bool {
    assert(emitter.depth <= brace.nest_depth_max);
    assert(emitter.count <= emitter.tokens.len);

    if (emitter.depth == 0) return false;

    const frame = line.frame(emitter);
    if (frame.kind != .block_start) return false;
    if (!classed_head(emitter, frame.open)) return false;

    const held = line.coded(emitter) orelse return true;
    const kind = emitter.tokens[held].kind;
    if (kind == .block_start) return true;
    if (kind.eql(.{ .punctuation = .semicolon })) return true;
    if (kind != .block_end) return false;

    const open = emitter.brackets.open_of(held) orelse return false;
    return member_body(emitter, open);
}

pub fn classed_head(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    if (core.memo_found(emitter, .classed_head, open, 0)) |answer| return answer == 1;

    const held = classed_head_scanned(emitter, open);

    core.memo_store(emitter, .classed_head, open, 0, @intFromBool(held));

    return held;
}

fn classed_head_scanned(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    const head = edge.statement_head(emitter, open) orelse return false;
    var scan = head;

    assert(head <= open);

    while (scan < open) : (scan += 1) {
        if (line.word_is(emitter, scan, core.class_words)) return true;
    }

    return false;
}

fn member_body(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    if (emit.roled(emitter, open, brace.role_type)) return false;

    const head = edge.statement_head(emitter, open) orelse return false;
    var scan = unite.decorated_word(emitter, head) orelse head;

    while (scan < open) {
        const kind = emitter.tokens[scan].kind;
        if (kind.eql(.{ .punctuation = .assign })) return false;
        if (kind.eql(.{ .punctuation = .colon })) return false;

        if (kind.eql(.{ .punctuation = .paren_open })) {
            const close = join.closing_of(emitter, scan) orelse return false;
            const after = emit.ahead_of(emitter, close) orelse return false;
            if (after == open) return true;
            return after < open and emitter.tokens[after].is_punctuation(.colon);
        }

        if (walk.is_open(kind)) scan = join.closing_of(emitter, scan) orelse open;

        scan += 1;
    }

    return false;
}

pub fn statement_braced(emitter: *const Emitter, close: u32) bool {
    assert(close < emitter.count);

    const root: edge.Statement = .{ .braced = .{ .close = close, .open = close, .phase = .start } };
    const answer = edge.statement_evaluated(emitter, root);

    return answer.verdict;
}

pub fn statement_braced_step(
    emitter: *const Emitter,
    frame: *edge.Braced,
    answer: ?edge.StatementAnswer,
) edge.StatementStep {
    assert(frame.close < emitter.count);
    assert(frame.open <= frame.close);
    assert((answer == null) == (frame.phase == .start));

    const returned = answer orelse return statement_braced_start(emitter, frame);

    assert(frame.open < frame.close);

    if (frame.phase == .bodied) {
        if (!returned.verdict) return .{ .done = .{ .verdict = false } };

        frame.phase = .plain;

        return .{ .call = edge.statement_scan_frame(emitter, frame.open, false) };
    }

    assert(frame.phase == .plain);

    const found = returned.head orelse return .{ .done = .{ .verdict = false } };

    assert(found <= frame.open);

    return .{ .done = .{ .verdict = statement_braced_head(emitter, found, frame.open) } };
}

fn statement_braced_start(emitter: *const Emitter, frame: *edge.Braced) edge.StatementStep {
    assert(frame.phase == .start);
    assert(frame.open == frame.close);

    const missed: edge.StatementStep = .{ .done = .{ .verdict = false } };
    if (statement_braced_string(emitter, frame.close)) return missed;

    const open = emitter.brackets.open_of(frame.close) orelse return missed;

    assert(open < frame.close);

    frame.open = open;
    frame.phase = .bodied;

    return .{ .call = .{ .bodied = .{ .position = open, .before = open } } };
}

fn statement_braced_head(emitter: *const Emitter, found: u32, open: u32) bool {
    assert(found <= open);
    assert(open < emitter.count);

    const head = statement_coded(emitter, found) orelse return false;
    if (head == open) return true;
    if (!words_contain(brace_heads, emitter.tokens[head].text(emitter.source))) return false;
    return brace_headed(emitter, head, open);
}

fn statement_braced_string(emitter: *const Emitter, close: u32) bool {
    assert(close < emitter.count);

    const held = emit.ahead_of(emitter, close) orelse return false;

    assert(held > close);

    if (emitter.tokens[held].kind != .string) return false;
    return tmpl.template_closes(emitter, close);
}

fn statement_coded(emitter: *const Emitter, found: u32) ?u32 {
    assert(found < emitter.count);

    if (emitter.tokens[found].kind != .comment) return found;

    const held = line.coding(emitter, found) orelse return null;

    assert(held > found);

    return held;
}

fn brace_headed(emitter: *const Emitter, head: u32, open: u32) bool {
    assert(head < open);
    assert(open < emitter.count);

    const before = emit.back_of(emitter, open) orelse return false;
    var word = head;

    if (walk.text_is(emitter.tokens[word].text(emitter.source), "else")) {
        if (emit.ahead_of(emitter, word)) |held| {
            if (walk.text_is(emitter.tokens[held].text(emitter.source), "if")) word = held;
        }
    }

    if (before == word) return true;

    var paren = emit.ahead_of(emitter, word) orelse return false;

    if (walk.text_is(emitter.tokens[paren].text(emitter.source), "await")) {
        paren = emit.ahead_of(emitter, paren) orelse return false;
    }

    if (!emitter.tokens[paren].is_punctuation(.paren_open)) return false;
    return join.closing_of(emitter, paren) == before;
}

pub fn declares_a_body(emitter: *const Emitter, close: u32) bool {
    assert(close < emitter.count);

    const answer = edge.statement_evaluated(emitter, .{ .declares = .{ .close = close } });
    return answer.verdict;
}

pub fn declares_a_body_step(
    emitter: *const Emitter,
    frame: *edge.Declares,
    answer: ?edge.StatementAnswer,
) edge.StatementStep {
    assert(frame.close < emitter.count);
    assert(emitter.count <= emitter.tokens.len);
    if (answer) |held| assert(held != .head or held.head == null or held.head.? < emitter.count);

    const returned = answer orelse return declares_a_body_start(emitter, frame);
    const found = returned.head orelse return .{ .done = .{ .verdict = false } };

    assert(found < frame.close);

    return .{ .done = .{ .verdict = declares_a_body_head(emitter, found, frame.close) } };
}

fn declares_a_body_start(emitter: *const Emitter, frame: *edge.Declares) edge.StatementStep {
    assert(frame.close < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    const missed: edge.StatementStep = .{ .done = .{ .verdict = false } };
    const open = emitter.brackets.open_of(frame.close) orelse return missed;

    assert(open < frame.close);

    if (emit.roled(emitter, open, brace.role_type)) return missed;
    return .{ .call = edge.statement_scan_frame(emitter, open, false) };
}

fn declares_a_body_head(emitter: *const Emitter, found: u32, close: u32) bool {
    assert(found < emitter.count);
    assert(close < emitter.count);

    const coded = statement_coded(emitter, found) orelse return false;
    const first = unite.decorated_word(emitter, coded) orelse coded;
    const open = emitter.brackets.open_of(close) orelse return false;
    var head = first;

    for (0..declare_prefixes.len + 1) |_| {
        if (!line.word_is(emitter, head, declare_prefixes)) break;

        head = line.coding(emitter, head) orelse return false;
    }

    if (head >= open) return false;

    const text = emitter.tokens[head].text(emitter.source);
    const plain = head == first and words_contain(core.declare_heads, text);
    if (plain) return true;
    if (!body_opened(emitter, head, open)) return false;
    if (words_contain(core.declare_heads, text)) return true;
    if (!words_contain(declare_named_heads, text)) return false;

    const name = line.coding(emitter, head) orelse return false;

    assert(name > head);

    return switch (emitter.tokens[name].kind) {
        .identifier, .string => true,
        else => false,
    };
}

fn body_opened(emitter: *const Emitter, head: u32, open: u32) bool {
    var depth: u32 = 0;

    assert(head < open);
    assert(open < emitter.count);

    for (head + 1..open + 1) |scan| {
        const kind = emitter.tokens[scan].kind;

        const opens = kind.eql(.{ .punctuation = .paren_open }) or
            kind.eql(.{ .punctuation = .bracket_open });

        const closes = kind.eql(.{ .punctuation = .paren_close }) or
            kind.eql(.{ .punctuation = .bracket_close });

        if (kind == .block_start) {
            if (depth == 0) return scan == open;
        }

        if (opens) depth += 1;
        if (closes) depth -|= 1;
    }

    return false;
}

fn words_contain(words: []const []const u8, text: []const u8) bool {
    assert(words.len > 0);
    assert(text.len <= std.math.maxInt(u32));

    for (words) |word| {
        assert(word.len > 0);

        if (walk.text_eql(word, text)) return true;
    }

    return false;
}
