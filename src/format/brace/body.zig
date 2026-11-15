const std = @import("std");
const assert = std.debug.assert;
const brace = @import("../brace.zig");
const core = @import("emitter.zig");
const edge = @import("edge.zig");
const emit = @import("emit.zig");
const jsx = @import("jsx.zig");
const line = @import("line.zig");
const list = @import("list.zig");
const reach = @import("../reach.zig");
const split = @import("split.zig");
const tern = @import("tern.zig");
const walk = @import("../walk.zig");
const Emitter = core.Emitter;

const statement_words: [11][]const u8 = .{
    "const",
    "export",
    "for",
    "function",
    "if",
    "import",
    "let",
    "return",
    "throw",
    "var",
    "while",
};

pub fn return_type_joined(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < emitter.count);

    if (!emitter.tokens[previous].is_punctuation(.colon)) return false;
    if (emitter.tokens[position].kind == .comment) return false;

    const held = emit.back_of(emitter, previous) orelse return false;
    if (!return_type_held(emitter, position, held)) return false;
    return !tern.ternary(emitter, previous);
}

fn return_type_held(emitter: *const Emitter, position: u32, held: u32) bool {
    assert(position < emitter.count);
    assert(held < emitter.count);

    const kind = emitter.tokens[held].kind;
    if (kind.eql(.{ .punctuation = .paren_close })) return true;

    const closed = kind == .block_end or kind.eql(.{ .punctuation = .bracket_close });
    if (!closed) return false;
    if (!emit.roled(emitter, position, brace.role_type)) return false;

    const text = emitter.tokens[position].text(emitter.source);
    if (walk.text_is(text, "|")) return false;
    return !walk.text_is(text, "&");
}

pub fn bodied_brace(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    if (core.memo_found(emitter, .bodied_brace, position, 0)) |answer| return answer == 1;

    const root: edge.Statement = .{ .bodied = .{ .position = position, .before = position } };
    const answer = edge.statement_evaluated(emitter, root);

    core.memo_store(emitter, .bodied_brace, position, 0, @intFromBool(answer.verdict));

    return answer.verdict;
}

pub fn bodied_brace_step(
    emitter: *const Emitter,
    frame: *edge.Bodied,
    answer: ?edge.StatementAnswer,
) edge.StatementStep {
    assert(frame.position < emitter.count);
    assert(frame.before <= frame.position);
    if (answer) |held| assert(held != .head or held.head == null or held.head.? < emitter.count);

    const found = answer orelse return bodied_brace_start(emitter, frame);

    assert(frame.before < frame.position);

    if (found.head) |held| {
        assert(held < frame.position);

        return .{ .done = .{ .verdict = true } };
    }

    const tail = bodied_brace_tail(emitter, frame.position, frame.before);
    return .{ .done = .{ .verdict = tail } };
}

fn bodied_brace_start(emitter: *const Emitter, frame: *edge.Bodied) edge.StatementStep {
    assert(frame.position < emitter.count);
    assert(frame.before == frame.position);

    if (bodied_brace_judged(emitter, frame)) |judged| return .{ .done = .{ .verdict = judged } };

    assert(frame.before < frame.position);

    return .{ .call = edge.statement_word_frame(emitter, frame.position) };
}

fn bodied_brace_judged(emitter: *const Emitter, frame: *edge.Bodied) ?bool {
    assert(frame.position < emitter.count);
    assert(frame.before == frame.position);

    const position = frame.position;
    if (emitter.tokens[position].kind != .block_start) return false;

    if (emitter.policy.angle_calls) {
        if (emitter.brackets.angles_at(position) > 0) return false;
    }

    const word = emit.word_before(emitter, position) orelse return true;
    const before = split.coded_at(emitter, word) orelse return true;
    const held = emitter.tokens[before];

    assert(before < position);

    if (jsx.holed(emitter, before)) return false;

    switch (held.kind) {
        .block_end, .block_start => return true,
        .punctuation => |punctuation| {
            if (punctuation == .paren_close) return true;
            if (punctuation == .semicolon) return true;
            if (emit.mark_of(emitter, before) & brace.mark_label != 0) return true;
        },
        else => {},
    }

    const text = held.text(emitter.source);
    if (word_in(text, &.{ "catch", "else", "do", "try", "finally" })) return true;

    if (emitter.policy.clause_lines) {
        if (walk.text_is(text, "static")) return true;
    }

    if (word_in(text, &.{ "keyof", "readonly", "unique" })) return false;
    if (walk.text_is(text, "extends")) return false;

    frame.before = before;

    return null;
}

fn bodied_brace_tail(emitter: *const Emitter, position: u32, before: u32) bool {
    assert(position < emitter.count);
    assert(before < position);

    const held = emitter.tokens[before];
    const text = held.text(emitter.source);

    if (held.is_punctuation(.colon)) {
        if (split.armed(emitter, before)) return true;
        return returned(emitter, before);
    }

    if (emitter.policy.type_words.len > 0) {
        if (word_in(text, &.{ "is", "|", "&" })) return false;
    }

    if (walk.text_is(text, "=>")) {
        emitter.statements.contextual = true;

        if (!emitter.typed) {
            if (!emit.roled(emitter, position, brace.role_type)) return true;
        }
    }

    return returned(emitter, before);
}

pub fn declared(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    const word = declared_word(emitter, position);

    if (word) |held| assert(held < position);

    return word != null;
}

pub fn class_valued(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    const word = declared_word(emitter, position) orelse return false;

    assert(word < position);

    if (!walk.text_is(emitter.tokens[word].text(emitter.source), "class")) return false;

    const held = emit.back_of(emitter, word) orelse return false;
    const text = emitter.tokens[held].text(emitter.source);

    return word_in(text, &.{ "(", ",", ":", "=", "=>", "?", "[", "new", "return" });
}

pub fn declared_word(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);

    if (core.memo_found(emitter, .declared_word, position, 0)) |answer| {
        return if (answer == core.memo_none) null else answer;
    }

    const held = declared_word_scanned(emitter, position);

    core.memo_store(emitter, .declared_word, position, 0, held orelse core.memo_none);

    return held;
}

fn declared_word_scanned(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);

    const answer = edge.statement_evaluated(emitter, edge.statement_word_frame(emitter, position));
    const word = answer.head;

    if (word) |held| assert(held < position);

    return word;
}

pub fn declared_word_step(
    emitter: *const Emitter,
    frame: *edge.Word,
    answer: ?edge.StatementAnswer,
) edge.StatementStep {
    assert(frame.position < emitter.count);
    assert(frame.steps <= core.type_scan_max);
    if (answer != null) assert(frame.waiting);

    const missed: edge.StatementStep = .{ .done = .{ .head = null } };

    if (answer) |member| {
        assert(frame.waiting);
        assert(frame.depth == 0);

        frame.waiting = false;

        if (!member.verdict) return .{ .done = .{ .head = frame.scan } };
        if (!declared_word_held(emitter, frame.scan)) return missed;

        frame.steps += 1;
    } else {
        assert(frame.steps == 0);

        if (emitter.policy.declaration_words.len == 0) return missed;
        if (emitter.brackets.angles_at(frame.position) > 0) return missed;
    }

    while (frame.steps < core.type_scan_max) : (frame.steps += 1) {
        if (declared_word_token(emitter, frame)) |step| return step;
    }

    return missed;
}

fn declared_word_token(emitter: *const Emitter, frame: *edge.Word) ?edge.StatementStep {
    assert(!frame.waiting);
    assert(frame.scan <= frame.position);

    const missed: edge.StatementStep = .{ .done = .{ .head = null } };
    if (frame.scan == 0) return missed;

    frame.scan -= 1;

    const token = emitter.tokens[frame.scan];
    const angled = frame.depth == 0 and walk.text_is(token.text(emitter.source), ">");

    if (angled) {
        if (tern.angle_opening(emitter, frame.scan)) |angle| {
            assert(angle < frame.scan);

            frame.scan = angle;

            return null;
        }
    }

    if (token.kind == .block_end) {
        if (frame.depth == 0) return missed;
    }

    if (walk.is_close(token.kind)) {
        frame.depth += 1;

        return null;
    }

    const opens = walk.is_open(token.kind) or walk.substituting(emitter.source, token);

    if (opens) {
        if (frame.depth == 0) return missed;

        frame.depth -= 1;

        return null;
    }

    if (frame.depth > 0) return null;

    const declares = line.word_is(emitter, frame.scan, emitter.policy.declaration_words) and
        declared_word_named(emitter, frame.scan);

    if (declares) {
        frame.waiting = true;

        return .{ .call = edge.statement_member_frame(emitter, frame.scan) };
    }

    if (!declared_word_held(emitter, frame.scan)) return missed;
    return null;
}

fn declared_word_named(emitter: *const Emitter, scan: u32) bool {
    assert(scan < emitter.count);
    assert(emitter.policy.declaration_words.len > 0);

    if (line.word_is(emitter, scan, &.{"class"})) return true;

    const name = emit.ahead_of(emitter, scan) orelse return false;

    return switch (emitter.tokens[name].kind) {
        .identifier, .keyword, .string => true,
        else => false,
    };
}

fn declared_word_held(emitter: *const Emitter, scan: u32) bool {
    assert(scan < emitter.count);
    assert(emitter.policy.declaration_words.len > 0);

    const token = emitter.tokens[scan];

    switch (token.kind) {
        .identifier, .keyword, .string => return true,
        else => {},
    }

    return word_in(token.text(emitter.source), &.{ ".", ",", "<", ">" });
}

pub fn returned(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    var angles: u32 = 0;
    var brackets: u32 = 0;
    var scan: ?u32 = position;

    for (0..core.type_scan_max) |read_index| {
        const read: u32 = @intCast(read_index);
        const held = scan orelse return false;
        const token = emitter.tokens[held];
        const text = token.text(emitter.source);

        assert(held <= position);

        if (token.kind == .block_end) {
            scan = returned_opened(emitter, held);

            continue;
        }

        if (token.is_punctuation(.paren_close)) {
            const nested = angles > 0 or brackets > 0 or returned_operand(emitter, held);

            if (nested) {
                scan = returned_opened(emitter, held);

                continue;
            }
        }

        if (token.kind == .comment) {
            scan = emit.word_before(emitter, held);

            continue;
        }

        if (!nested_type(text, &angles, &brackets)) return false;

        if (token.is_punctuation(.colon)) {
            if (read == 0) return false;
            return returned_colon(emitter, held);
        }

        if (!returned_typed(emitter, held, read)) return false;

        scan = emit.word_before(emitter, held);
    }

    return false;
}

fn returned_opened(emitter: *const Emitter, close: u32) ?u32 {
    assert(close < emitter.count);
    assert(walk.is_close(emitter.tokens[close].kind));

    const open = emitter.brackets.open_of(close) orelse return null;
    return emit.word_before(emitter, open);
}

fn returned_colon(emitter: *const Emitter, colon: u32) bool {
    assert(colon < emitter.count);
    assert(emitter.tokens[colon].is_punctuation(.colon));

    if (reach.branched(emitter.source, emitter.tokens, emitter.brackets, colon)) return false;

    const before = emit.word_before(emitter, colon) orelse return false;
    return emitter.tokens[before].is_punctuation(.paren_close);
}

fn returned_typed(emitter: *const Emitter, held: u32, read: u32) bool {
    assert(held < emitter.count);
    assert(read < core.type_scan_max);

    const token = emitter.tokens[held];
    const text = token.text(emitter.source);
    const imported = walk.text_is(text, "import") and returned_import(emitter, held);

    if (word_in(text, &statement_words)) {
        if (!imported) return false;
    }

    switch (token.kind) {
        .identifier, .keyword, .number, .string => return true,
        else => {},
    }

    if (word_in(text, &.{ ".", "<", ">", "[", "]", "|", "&", "," })) return true;
    if (!walk.text_is(text, "=>")) return false;
    return read > 0;
}

fn returned_import(emitter: *const Emitter, held: u32) bool {
    assert(held < emitter.count);
    assert(walk.text_is(emitter.tokens[held].text(emitter.source), "import"));

    const after = emit.ahead_of(emitter, held) orelse return false;
    return emitter.tokens[after].is_punctuation(.paren_open);
}

fn returned_operand(emitter: *const Emitter, close: u32) bool {
    assert(close < emitter.count);
    assert(emitter.tokens[close].is_punctuation(.paren_close));

    const held = emit.ahead_of(emitter, close) orelse return false;
    const text = emitter.tokens[held].text(emitter.source);

    return word_in(text, &.{ "&", "=>", "[", "|" });
}

fn nested_type(text: []const u8, angles: *u32, brackets: *u32) bool {
    assert(text.len <= std.math.maxInt(u32));

    const brackets_before = brackets.*;

    if (walk.text_is(text, "<")) {
        if (angles.* == 0) return false;

        angles.* -= 1;

        return true;
    }

    if (closes_angles(text)) {
        angles.* += @intCast(text.len);

        return true;
    }

    if (walk.text_is(text, "[")) {
        if (brackets.* == 0) return false;

        brackets.* -= 1;

        return true;
    }

    if (walk.text_is(text, "]")) brackets.* += 1;

    assert(brackets.* >= brackets_before);

    return true;
}

fn closes_angles(text: []const u8) bool {
    assert(text.len <= std.math.maxInt(u32));

    if (text.len == 0) return false;

    for (text) |byte| {
        if (byte != '>') return false;
    }

    assert(text[0] == '>');

    return true;
}

pub fn parting(emitter: *const Emitter, from: u32, to: u32) bool {
    assert(from < emitter.count);
    assert(to <= emitter.count);

    if (!emitter.policy.body_parts) return false;

    var scan = from;

    while (scan < to) : (scan += 1) {
        assert(scan < emitter.count);

        if (parts_after(emitter, scan, from)) return true;
    }

    return false;
}

pub fn parts(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    if (!emitter.policy.body_parts) return false;
    if (!bodied_brace(emitter, position)) return false;

    const held = emit.ahead_of(emitter, position) orelse return false;

    assert(held > position);

    return emitter.tokens[held].kind != .block_end;
}

fn parts_after(emitter: *const Emitter, position: u32, open: u32) bool {
    assert(position < emitter.count);
    assert(open < emitter.count);

    if (parts(emitter, position)) return true;
    if (split.arms(emitter, position)) return true;
    if (ends_statement(emitter, position, open)) return true;
    return tern.ternary_parted(emitter, position);
}

fn ends_statement(emitter: *const Emitter, position: u32, open: u32) bool {
    assert(position < emitter.count);
    assert(open < emitter.count);

    if (!bodied_brace(emitter, open)) return false;
    return parted_statement(emitter, position);
}

pub fn parted_by(emitter: *const Emitter, from: u32, to: u32) u32 {
    assert(from <= to);
    assert(to <= emitter.source.len);

    return emitter.breaks.counted(from, to);
}

pub fn parts_at(emitter: *const Emitter, previous: u32, position: u32) bool {
    assert(previous < emitter.count);
    assert(position < emitter.count);

    const from = emitter.tokens[previous].end();
    const to = emitter.tokens[position].offset;

    return parted_by(emitter, from, to) > 0;
}

fn word_in(text: []const u8, words: []const []const u8) bool {
    assert(words.len > 0);
    assert(text.len <= std.math.maxInt(u32));

    for (words) |word| {
        if (walk.text_eql(text, word)) return true;
    }

    return false;
}

pub fn parted_statement(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count <= emitter.tokens.len);

    if (!emitter.policy.body_parts) return false;
    if (emitter.tokens[position].is_punctuation(.semicolon)) return true;
    return list.membered(emitter, position);
}

pub fn ends(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.depth == 0) return false;

    const frame = emitter.nest[emitter.depth - 1];
    if (frame.close != position) return false;
    return parts(emitter, frame.open);
}
