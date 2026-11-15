const std = @import("std");
const assert = std.debug.assert;
const body = @import("body.zig");
const call = @import("call.zig");
const core = @import("emitter.zig");
const emit = @import("emit.zig");
const join = @import("join.zig");
const line = @import("line.zig");
const list = @import("list.zig");
const own = @import("own.zig");
const span = @import("span.zig");
const split = @import("split.zig");
const tern = @import("tern.zig");
const walk = @import("../walk.zig");
const Emitter = core.Emitter;
const Token = @import("../../syntax/token.zig");
const chain_scan_max: u32 = 512;
const dangling_scan_max: u32 = 1024;
const else_comment_max: u32 = 16;
const module_star_max: u32 = 4;
const comment_member_max: u32 = 64;
const shift_head_max: u32 = 3;
const union_comment_scan_max: u32 = 4096;

pub fn keyword_commented(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < emitter.count);

    if (emitter.tokens[position].kind != .comment) return false;
    if (emitter.tokens[previous].kind != .keyword) return false;

    const text = emitter.tokens[previous].text(emitter.source);
    return word_in(text, &.{ "const", "function", "let", "var" });
}

pub fn keyword_comment_level(emitter: *const Emitter, leading: u32) ?u32 {
    assert(leading < emitter.count);

    const comment = emit.back_of(emitter, leading) orelse return null;
    if (emitter.tokens[comment].kind != .comment) return null;

    const held = emit.back_of(emitter, comment) orelse return null;

    assert(held < comment);

    if (emitter.tokens[held].kind != .keyword) return null;
    if (!walk.text_is(emitter.tokens[held].text(emitter.source), "function")) return null;
    return emitter.printed;
}

pub fn union_comment_level(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);

    if (emitter.tokens[position].kind != .comment) return null;

    const semicolon = emit.back_of(emitter, position) orelse return null;
    if (!emitter.tokens[semicolon].is_punctuation(.semicolon)) return null;

    const ended = emit.back_of(emitter, semicolon) orelse return null;
    const found = line.at(emitter, ended) orelse return null;
    const bar = found.start - 1;
    if (!walk.text_is(emitter.tokens[bar].text(emitter.source), "|")) return null;
    return union_comment_scan(emitter, position, bar, found.level);
}

fn union_comment_scan(emitter: *const Emitter, position: u32, bar: u32, level: u32) ?u32 {
    assert(position < emitter.count);
    assert(bar < position);
    assert(level < std.math.maxInt(u32));

    var depth: u32 = 0;
    var scan = bar;

    for (0..union_comment_scan_max) |_| {
        scan = emit.back_of(emitter, scan) orelse return null;

        const kind = emitter.tokens[scan].kind;

        if (walk.is_close(kind)) {
            depth += 1;
        } else if (walk.is_open(kind)) {
            if (depth == 0) return null;

            depth -= 1;
        } else {
            const assigned = kind.eql(.{ .punctuation = .assign }) or
                kind.eql(.{ .punctuation = .colon });

            const seated = depth == 0 and assigned;
            if (seated) return union_comment_seated(emitter, position, bar, scan, level);
        }
    }

    return null;
}

fn union_comment_seated(
    emitter: *const Emitter,
    position: u32,
    bar: u32,
    scan: u32,
    level: u32,
) ?u32 {
    assert(scan < bar);
    assert(bar < position);

    const found = line.at(emitter, scan) orelse return null;
    const head = found.start;
    const column = source_column(emitter, position);
    if (column < source_column(emitter, bar)) return null;
    if (column <= source_column(emitter, head - 1)) return null;
    return level;
}

fn source_column(emitter: *const Emitter, position: u32) u32 {
    assert(position < emitter.count);

    const offset = emitter.tokens[position].offset;
    const before = emitter.source[0..offset];
    const newline = std.mem.findScalarLast(u8, before, '\n');
    const column: u32 = if (newline) |at| @intCast(before.len - at - 1) else offset;

    assert(column <= offset);

    return column;
}

pub fn dangling_blank(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < emitter.count);

    if (!emitter.policy.dangling_blanks) return false;
    if (emitter.tokens[position].kind != .comment) return false;
    if (emitter.tokens[previous].kind != .comment) return false;

    const open = comment_edge(emitter, previous, false) orelse return false;
    const close = comment_edge(emitter, position, true) orelse return false;

    assert(open < close);

    if (!walk.is_open(emitter.tokens[open].kind)) return false;
    return emitter.brackets.close_of(open) == close;
}

fn comment_edge(emitter: *const Emitter, position: u32, forward: bool) ?u32 {
    assert(position < emitter.count);
    assert(emitter.tokens[position].kind == .comment);

    var scan = position;

    for (0..dangling_scan_max) |_| {
        const held = if (forward) emit.ahead_of(emitter, scan) else emit.back_of(emitter, scan);
        const found = held orelse return null;

        assert(found != scan);

        if (emitter.tokens[found].kind != .comment) return found;

        scan = found;
    }

    return null;
}

pub fn dangling_part(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < emitter.count);

    return dangling_blank(emitter, position, previous);
}

pub fn operator_blanked(emitter: *const Emitter) bool {
    assert(emitter.wraps_owed <= core.wrap_depth_max);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.chain_simples) return false;

    const held = emitter.previous orelse return false;
    if (span.wrapping_operator(emitter, held)) return true;
    return operator_commented(emitter, held);
}

pub fn part_blanked(emitter: *const Emitter) bool {
    assert(emitter.wraps_owed <= core.wrap_depth_max);
    assert(emitter.count == emitter.tokens.len);

    return operator_blanked(emitter);
}

fn operator_commented(emitter: *const Emitter, previous: u32) bool {
    assert(previous < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (emitter.tokens[previous].kind != .comment) return false;

    const held = join.coded_before(emitter, previous) orelse return false;

    assert(held < previous);

    if (!span.wrapping_operator(emitter, held)) return false;

    const from = emitter.tokens[held].end();
    const to = emitter.tokens[previous].offset;

    return body.parted_by(emitter, from, to) == 0;
}

pub fn module_blank(emitter: *const Emitter) bool {
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.chain_simples) return false;

    const last = emitter.previous orelse return false;

    assert(last < emitter.count);

    for (emitter.tokens[0..emitter.count]) |token| {
        const coded = token.kind != .newline and token.length > 0 and token.kind != .comment;
        if (coded) return false;
    }

    const after = emitter.source[emitter.tokens[last].end()..];
    const at = std.mem.findScalar(u8, after, '\n') orelse return false;

    return std.mem.findScalar(u8, after[at + 1 ..], '\n') != null;
}

pub fn separated(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);

    if (!emitter.tokens[position].is_punctuation(.semicolon)) return null;
    if (emitter.depth == 0) return null;
    if (!comment_membered(emitter)) return null;

    const comment = emit.ahead_of(emitter, position) orelse return null;
    const token = emitter.tokens[comment];

    assert(comment > position);

    if (token.kind != .comment) return null;
    if (std.mem.startsWith(u8, token.text(emitter.source), "//")) return null;
    if (body.parts_at(emitter, position, comment)) return null;
    return comment;
}

fn comment_membered(emitter: *const Emitter) bool {
    assert(emitter.depth > 0);

    const frame = line.frame(emitter);
    if (frame.kind != .block_start) return false;
    if (span.type_framed(emitter, frame.open)) return true;

    var scan = frame.open;

    for (0..comment_member_max) |_| {
        const held = emit.back_of(emitter, scan) orelse return false;
        const kind = emitter.tokens[held].kind;

        assert(held < scan);

        if (walk.is_close(kind)) return false;
        if (walk.is_open(kind)) return false;
        if (kind.eql(.{ .punctuation = .semicolon })) return false;
        if (walk.text_is(emitter.tokens[held].text(emitter.source), "interface")) return true;

        scan = held;
    }

    return false;
}

pub fn separates(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);

    var comment = separated(emitter, position) orelse return;

    assert(comment > position);

    for (0..emitter.count) |_| {
        emitter.comment_after = comment;

        try emitter.document.push(.space);
        try emitter.document.push(.{ .verbatim = emit.written(emitter, comment) });

        comment = separated_next(emitter, comment) orelse break;
    }
}

fn separated_next(emitter: *const Emitter, comment: u32) ?u32 {
    assert(comment < emitter.count);
    assert(emitter.tokens[comment].kind == .comment);

    const next = emit.ahead_of(emitter, comment) orelse return null;
    const token = emitter.tokens[next];
    if (token.kind != .comment) return null;
    if (std.mem.startsWith(u8, token.text(emitter.source), "//")) return null;
    if (body.parts_at(emitter, comment, next)) return null;
    return next;
}

pub fn back(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);

    var scan = position;

    for (0..emitter.count) |_| {
        scan = emit.back_of(emitter, scan) orelse return null;

        assert(scan < position);

        if (emitter.tokens[scan].kind != .comment) return scan;
    }

    return null;
}

pub fn commented_clause(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < emitter.count);

    if (!emitter.policy.header_parens) return false;
    if (!emitter.tokens[previous].is_punctuation(.paren_close)) return false;
    if (emitter.tokens[position].kind == .block_start) return false;

    const open = emit.opened(emitter, previous) orelse return false;
    if (!split.headed(emitter, open)) return false;

    var depth: u32 = 0;
    var scan = position;

    while (scan < emitter.count) : (scan += 1) {
        const token = emitter.tokens[scan];
        const opens = walk.is_open(token.kind) or token.kind == .block_start;
        const closes = walk.is_close(token.kind) or token.kind == .block_end;

        if (opens) {
            depth += 1;
        } else if (closes) {
            if (depth == 0) return false;

            depth -= 1;
        } else if (depth == 0) {
            if (token.is_punctuation(.semicolon)) return commented_else(emitter, scan);
        } else {}
    }

    return false;
}

pub fn suffixed(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    const token = emitter.tokens[position];

    if (!emitter.policy.chain_simples) return false;
    if (token.kind != .comment) return false;
    if (!std.mem.startsWith(u8, token.text(emitter.source), "//")) return false;

    const before = emit.back_of(emitter, position) orelse return false;
    const held = emit.ahead_of(emitter, position) orelse return false;

    assert(before < position);

    if (!emitter.tokens[held].is_punctuation(.semicolon)) return false;
    if (emitter.tokens[before].kind == .comment) return false;
    if (body.parts_at(emitter, before, position)) return false;
    if (!line.statement_level(emitter)) return false;

    for (emitter.wrapped[0..emitter.wraps_owed]) |wrapped| {
        if (wrapped.wrap == .parens) return false;
    }

    return true;
}

fn block_comment(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    const token = emitter.tokens[position];
    const text = token.text(emitter.source);

    if (token.kind != .comment) return false;
    if (!std.mem.startsWith(u8, text, "/*")) return false;
    return std.mem.findScalar(u8, text, '\n') == null;
}

pub fn else_commented(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    if (!block_comment(emitter, position)) return false;

    const close = join.coded_before(emitter, position) orelse return false;
    const first = emit.ahead_of(emitter, close) orelse return false;

    if (emitter.tokens[close].kind != .block_end) return false;
    if (!body.parts_at(emitter, close, first)) return false;

    var scan = first;

    for (0..else_comment_max) |_| {
        if (!block_comment(emitter, scan)) {
            const open = else_opened(emitter, scan) orelse return false;
            const held = emit.ahead_of(emitter, open) orelse return false;
            const kind = emitter.tokens[held].kind;

            assert(held > open);

            return kind != .block_end and kind != .comment;
        }

        scan = emit.ahead_of(emitter, scan) orelse return false;
    }

    return false;
}

fn else_opened(emitter: *const Emitter, word: u32) ?u32 {
    assert(word < emitter.count);

    if (!line.word_is(emitter, word, &.{"else"})) return null;

    var open = emit.ahead_of(emitter, word) orelse return null;

    if (line.word_is(emitter, open, &.{"if"})) {
        const paren = emit.ahead_of(emitter, open) orelse return null;
        const close = emitter.brackets.close_of(paren) orelse return null;

        open = emit.ahead_of(emitter, close) orelse return null;
    }

    assert(open > word);

    if (emitter.tokens[open].kind != .block_start) return null;
    return open;
}

pub fn else_comments(emitter: *Emitter, position: u32) error{Overflow}!void {
    assert(position < emitter.count);

    const open = emit.back_of(emitter, position) orelse return;
    var word = emit.back_of(emitter, open) orelse return;

    if (emitter.tokens[word].is_punctuation(.paren_close)) {
        if (else_comments_header(emitter, word)) |before| word = before;
    }

    const else_open = else_opened(emitter, word) orelse return;
    if (else_open != open) return;

    var first = emit.back_of(emitter, word) orelse return;

    for (0..else_comment_max) |_| {
        const held = emit.back_of(emitter, first) orelse break;
        if (!block_comment(emitter, held)) break;

        first = held;
    }

    const previous = join.coded_before(emitter, first) orelse return;

    assert(first < word);

    if (!else_commented(emitter, first)) return;

    try line.level(emitter, emitter.printed);
    try else_comments_written(emitter, first, word, previous);
}

fn else_comments_header(emitter: *const Emitter, word: u32) ?u32 {
    assert(word < emitter.count);
    assert(emitter.tokens[word].is_punctuation(.paren_close));

    const paren = emitter.brackets.open_of(word) orelse return null;
    const held = emit.back_of(emitter, paren) orelse return null;
    const before = emit.back_of(emitter, held) orelse return null;

    assert(before < held);

    return before;
}

fn else_comments_written(
    emitter: *Emitter,
    first: u32,
    word: u32,
    coded: u32,
) error{Overflow}!void {
    assert(first < word);
    assert(word < emitter.count);
    assert(coded < std.math.maxInt(u32));

    var previous = coded;
    var scan = first;

    for (0..else_comment_max) |_| {
        if (scan >= word) break;

        const from = emitter.tokens[previous].end();
        const to = emitter.tokens[scan].offset;

        switch (body.parted_by(emitter, from, to)) {
            0 => try emitter.document.push(.space),
            1 => try emitter.document.push(.hard_line),
            else => {
                try emitter.document.push(.hard_line);
                try emitter.document.push(.{ .blank_line = 1 });
            },
        }

        try emitter.document.push(.{ .verbatim = emit.written(emitter, scan) });

        previous = scan;
        scan = emit.ahead_of(emitter, scan) orelse return error.Overflow;
    }
}

pub fn commented_tail(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    const held = emitter.previous orelse return false;

    assert(held < emitter.count);

    if (!own.trailed_comma(emitter, held)) return false;
    return body.parts_at(emitter, held, position);
}

pub fn header_semi_gap(emitter: *const Emitter, previous: u32, position: u32) bool {
    assert(previous < emitter.count);
    assert(position < emitter.count);

    if (!emitter.tokens[previous].is_punctuation(.semicolon)) return false;
    if (!emitter.tokens[position].is_punctuation(.paren_close)) return false;

    const open = emitter.brackets.open_of(position) orelse return false;
    return header_clauses(emitter, open);
}

pub fn header_clauses(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    const held = emit.back_of(emitter, open) orelse return false;
    if (!walk.text_is(emitter.tokens[held].text(emitter.source), "for")) return false;

    const close = join.closing_of(emitter, open) orelse return false;

    assert(close > open);

    for (emitter.tokens[open + 1 .. close]) |token| {
        const coded = token.kind != .newline and token.length > 0 and
            !token.is_punctuation(.semicolon);

        if (coded) return true;
    }

    return false;
}

pub fn return_joined(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < emitter.count);

    if (!emitter.policy.return_parens) return false;

    const text = emitter.tokens[previous].text(emitter.source);
    if (!word_in(text, &.{ "return", "throw" })) return false;

    if (emit.back_of(emitter, previous)) |held| {
        if (emit.is_dot(emitter, held)) return false;
    }

    return switch (emitter.tokens[position].kind) {
        .block_end, .comment => false,
        .punctuation => |punctuation| punctuation != .semicolon,
        else => true,
    };
}

pub fn star_word(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    if (!emitter.policy.chain_simples) return false;
    if (!walk.text_is(emitter.tokens[position].text(emitter.source), "*")) return false;

    const held = back(emitter, position) orelse return false;
    const text = emitter.tokens[held].text(emitter.source);

    assert(held < position);

    return word_in(text, &.{ "function", "yield" });
}

pub fn module_star(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < emitter.count);

    if (!emitter.policy.chain_simples) return false;

    const held = emitter.tokens[previous].text(emitter.source);
    if (walk.text_is(held, "*")) return module_word(emitter, previous);
    if (!walk.text_is(emitter.tokens[position].text(emitter.source), "*")) return false;
    return module_word(emitter, position);
}

pub fn generator_star(emitter: *const Emitter, previous: u32) bool {
    assert(previous < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.chain_simples) return false;
    if (!walk.text_is(emitter.tokens[previous].text(emitter.source), "*")) return false;

    const before = back(emitter, previous) orelse return false;

    if (module_word(emitter, previous)) return false;

    const token = emitter.tokens[before];
    if (token.kind == .block_start) return true;
    if (token.kind == .block_end) return true;
    if (token.is_punctuation(.comma)) return true;
    if (token.is_punctuation(.semicolon)) return true;
    return word_in(token.text(emitter.source), &.{ "async", "get", "set", "static" });
}

pub fn binary_leads(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    if (!emitter.policy.binary_lines) return false;
    if (emitter.wraps_owed == 0) return false;

    const held = emitter.wrapped[emitter.wraps_owed - 1];

    switch (held.wrap) {
        .argued, .paired, .parens, .valued => {},
        else => return false,
    }

    if (held.depth != emitter.depth) return false;
    if (position >= held.close) return false;
    return call.binary_floored(emitter, position, held.floor);
}

pub fn shift_head(emitter: *const Emitter, position: u32) u32 {
    assert(position < emitter.count);

    var head = position;

    for (0..shift_head_max) |_| {
        if (head == 0) break;
        if (!span.shifted_pair(emitter, head - 1, head)) break;

        head -= 1;
    }

    assert(head <= position);

    return head;
}

pub fn binary_wrapped(emitter: *const Emitter) bool {
    assert(emitter.wraps_owed <= core.wrap_depth_max);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.binary_lines) return false;
    if (emitter.wraps_owed == 0) return false;
    return binary_wraps(emitter, emitter.wrapped[emitter.wraps_owed - 1]);
}

pub fn blocked(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    const token = emitter.tokens[position];
    if (token.kind != .comment) return false;
    return std.mem.startsWith(u8, token.text(emitter.source), "/*");
}

pub fn dotted(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);

    if (!emitter.policy.chain_simples) return null;
    if (!emit.is_dot(emitter, position)) return null;

    const previous = emitter.previous orelse return null;
    if (body.parts_at(emitter, previous, position)) return null;
    if (emitter.tokens[previous].kind == .comment) return null;

    const comment = emit.ahead_of(emitter, position) orelse return null;
    const token = emitter.tokens[comment];

    assert(comment > position);

    if (token.kind != .comment) return null;
    if (!std.mem.startsWith(u8, token.text(emitter.source), "//")) return null;
    if (body.parts_at(emitter, position, comment)) return null;

    const name = emit.ahead_of(emitter, comment) orelse return null;
    if (emitter.tokens[name].kind == .comment) return null;
    return comment;
}

pub fn opened(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < emitter.count);

    if (!emitter.policy.brace_comments) return false;

    const token = emitter.tokens[position];
    if (token.kind != .comment) return false;
    if (!std.mem.startsWith(u8, token.text(emitter.source), "//")) return false;
    return walk.is_open(emitter.tokens[previous].kind);
}

fn word_in(text: []const u8, words: []const []const u8) bool {
    assert(words.len > 0);
    assert(text.len <= std.math.maxInt(u32));

    for (words) |word| {
        if (walk.text_eql(text, word)) return true;
    }

    return false;
}

pub fn run_leveled(emitter: *Emitter) error{Overflow}!void {
    assert(emitter.wraps_owed <= core.wrap_depth_max);
    assert(emitter.depth <= emitter.count);

    const level = run_level(emitter) orelse return;

    try line.level(emitter, level);
}

fn run_level(emitter: *const Emitter) ?u32 {
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    if (!emitter.policy.binary_lines) return null;
    if (emitter.wraps_owed == 0) return null;

    const at = emitter.wraps_owed - 1;
    if (!emitter.wraps_armed[at]) return null;
    if (!binary_wraps(emitter, emitter.wrapped[at])) return null;

    const level = emitter.wraps_indent[at];
    if (level >= emitter.indent) return null;
    return level;
}

pub fn leads_line(emitter: *const Emitter, comment: u32) bool {
    assert(comment < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const token = emitter.tokens[comment];
    if (token.kind != .comment) return false;
    if (std.mem.startsWith(u8, token.text(emitter.source), "//")) return false;

    const before = emit.back_of(emitter, comment) orelse return false;
    if (!body.parts_at(emitter, before, comment)) return false;

    const held = emit.ahead_of(emitter, comment) orelse return false;

    assert(held > comment);

    if (!body.parts_at(emitter, comment, held)) return false;
    return !walk.is_close(emitter.tokens[held].kind);
}

pub fn spanned(emitter: *const Emitter, opens: u32, stop: u32) u32 {
    assert(emitter.wraps_owed <= core.wrap_depth_max);
    assert(emitter.count == emitter.tokens.len);
    assert(opens < std.math.maxInt(u32));

    if (opens < stop) return list.comment_skipped(emitter, opens);
    return opens;
}

fn commented_else(emitter: *const Emitter, semicolon: u32) bool {
    assert(semicolon < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var commented = false;
    var scan = semicolon + 1;

    while (scan < emitter.count) : (scan += 1) {
        const token = emitter.tokens[scan];
        if (token.kind == .newline) continue;
        if (token.length == 0) continue;

        if (token.kind == .comment) {
            const lined = std.mem.startsWith(u8, token.text(emitter.source), "//");

            commented = commented or lined;

            continue;
        }

        if (!commented) return false;
        return walk.text_is(token.text(emitter.source), "else");
    }

    return false;
}

pub fn suffix_owed(emitter: *const Emitter, comment: u32, position: u32) bool {
    assert(comment < emitter.count);
    assert(position < emitter.count);

    const held = emit.ahead_of(emitter, comment) orelse return false;
    if (held != position) return false;
    if (!emitter.tokens[position].is_punctuation(.semicolon)) return false;
    return suffixed(emitter, comment);
}

pub fn else_trailed(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < emitter.count);

    if (!block_comment(emitter, previous)) return false;
    if (!line.word_is(emitter, position, &.{"else"})) return false;

    const held = emit.back_of(emitter, previous) orelse return false;

    assert(held < previous);

    if (emitter.tokens[held].kind != .block_end) return false;
    return !body.parts_at(emitter, held, previous);
}

fn module_word(emitter: *const Emitter, star: u32) bool {
    assert(star < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var scan = star;

    for (0..module_star_max) |_| {
        const held = emit.back_of(emitter, scan) orelse return false;
        const token = emitter.tokens[held];
        const text = token.text(emitter.source);

        assert(held < scan);

        if (word_in(text, &.{ "export", "import" })) return true;

        if (token.kind != .identifier) {
            if (!token.is_punctuation(.comma)) return false;
        }

        scan = held;
    }

    return false;
}

fn binary_wraps(emitter: *const Emitter, held: core.Wrapped) bool {
    assert(emitter.wraps_owed > 0);
    assert(emitter.count == emitter.tokens.len);
    assert(held.start < emitter.count);

    switch (held.wrap) {
        .argued, .bodied, .paired, .parens, .valued => {},
        else => return false,
    }

    if (held.depth != emitter.depth) return false;

    const found = emitter.previous orelse return false;
    if (found >= held.close) return false;
    if (!call.binary_floored(emitter, shift_head(emitter, found), held.floor)) return false;
    return !span.shift_tailed(emitter, found);
}

pub fn binary_arms(emitter: *Emitter) error{Overflow}!void {
    assert(emitter.wraps_owed <= core.wrap_depth_max);
    assert(emitter.count == emitter.tokens.len);

    if (emitter.wraps_owed == 0) return;

    const at = emitter.wraps_owed - 1;
    if (emitter.wraps_armed[at]) return;
    if (emitter.wraps_nested[at] == core.nest_bare) return;
    if (!binary_wraps(emitter, emitter.wrapped[at])) return;

    emitter.wraps_armed[at] = true;

    if (emitter.wraps_nested[at] == core.nest_right) try emitter.document.push(.group_open);

    try line.opens_broken(emitter);
}

pub fn chained(emitter: *const Emitter, head: u32) ?u32 {
    assert(head < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const token = emitter.tokens[head];

    if (token.kind != .identifier) {
        if (!walk.text_is(token.text(emitter.source), "this")) return null;
    }

    var end = head;
    var previous = head;
    var commented = false;
    var scan = head;

    for (0..chain_scan_max) |_| {
        const ahead = emit.ahead_of(emitter, scan) orelse break;
        const piece = emitter.tokens[ahead];
        if (piece.is_punctuation(.semicolon)) break;

        if (piece.kind == .comment) {
            const chain_dotted = comment_chain_dotted(emitter, previous, ahead);

            commented = commented or chain_dotted;
            scan = ahead;

            continue;
        }

        if (walk.is_open(piece.kind)) {
            const close = join.closing_of(emitter, ahead) orelse return null;

            end = close;
            previous = close;
            scan = close;

            continue;
        }

        if (!comment_chain_link(emitter, ahead)) return null;

        end = ahead;
        previous = ahead;
        scan = ahead;
    }

    if (!commented) return null;
    return end;
}

fn comment_chain_dotted(emitter: *const Emitter, previous: u32, comment: u32) bool {
    assert(previous < comment);
    assert(comment < emitter.count);

    const after = line.coding(emitter, comment) orelse return false;
    if (!emit.is_dot(emitter, after)) return false;
    return body.parts_at(emitter, previous, comment);
}

fn comment_chain_link(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const token = emitter.tokens[position];

    if (emit.is_dot(emitter, position)) return true;
    if (token.kind == .identifier) return true;
    return walk.text_is(token.text(emitter.source), "!");
}

pub fn argued_wrapped(emitter: *const Emitter) bool {
    assert(emitter.wraps_owed <= core.wrap_depth_max);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.binary_lines) return false;
    if (emitter.wraps_owed == 0) return false;
    if (!argued_listed(emitter)) return false;

    const found = emitter.wrapped[emitter.wraps_owed - 1];
    if (found.wrap != .argued) return false;

    const lead = back(emitter, found.start) orelse return false;

    if (lead != line.frame(emitter).open) {
        if (!emitter.tokens[lead].is_punctuation(.comma)) return false;
    }

    return binary_wraps(emitter, found);
}

fn argued_listed(emitter: *const Emitter) bool {
    assert(emitter.wraps_owed > 0);
    assert(emitter.count == emitter.tokens.len);

    if (emitter.depth == 0) return false;
    if (!list.spreads(emitter)) return false;

    const open = line.frame(emitter).open;
    if (list.calling(emitter, open)) return true;
    if (list.bracket_lookup(emitter, open)) return true;
    return list.arrow_sequenced(emitter, open);
}

pub fn commented_space(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < emitter.count);

    const held = emitter.tokens[previous].kind;

    if (blocked(emitter, position)) {
        if (walk.is_open(held)) return false;
        return held != .block_start;
    }

    const token = emitter.tokens[position];

    if (emit.is_dot(emitter, position)) return false;
    if (commented_list_end(emitter, token.kind)) return true;
    if (commented_inside(emitter, token.kind)) return true;
    if (walk.is_close(token.kind)) return false;
    if (token.kind == .block_end) return false;
    if (token.is_punctuation(.comma)) return false;
    if (token.is_punctuation(.colon)) return tern.ternary(emitter, position);
    return !token.is_punctuation(.semicolon);
}

fn commented_inside(emitter: *const Emitter, kind: Token.Kind) bool {
    assert(emitter.depth <= emitter.nest.len);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.chain_simples) return false;
    if (kind != .block_end) return false;
    return line.frame(emitter).inside;
}

fn commented_list_end(emitter: *const Emitter, kind: Token.Kind) bool {
    assert(emitter.depth <= emitter.nest.len);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.chain_simples) return false;
    if (kind != .block_end) return false;

    const framed = line.frame(emitter);
    if (framed.kind != .block_start) return false;

    const found = emit.word_before(emitter, framed.open) orelse return false;
    return line.word_is(emitter, found, emitter.policy.list_words);
}
