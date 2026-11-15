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
const edge = @import("edge.zig");
const emit = @import("emit.zig");
const heritage = @import("heritage.zig");
const jsx = @import("jsx.zig");
const join = @import("join.zig");
const key = @import("key.zig");
const lead = @import("lead.zig");
const line = @import("line.zig");
const link = @import("link.zig");
const list = @import("list.zig");
const own = @import("own.zig");
const padded = @import("../text.zig").spaced;
const chain_key_parted = @import("value.zig").chain_key_parted;
const requoted = @import("../text.zig").requoted;
const semi = @import("semi.zig");
const sole = @import("sole.zig");
const split = @import("split.zig");
const stream = @import("../stream.zig");
const tags = @import("tags.zig");
const tern = @import("tern.zig");
const tmpl = @import("tmpl.zig");
const unite = @import("unite.zig");
const walk = @import("../walk.zig");
const wide = @import("wide.zig");
const wrap = @import("wrap.zig");
const Emitter = core.Emitter;
const Frame = core.Frame;

pub const Union = struct {
    bars: [union_member_max]u32,
    count: u32,
    head: u32,
    lead: ?u32,
    open: u32,
    stop: u32,
};

const Scopes = struct {
    depth: u32,
    held: [brace.nest_depth_max]bool,

    const empty: Scopes = .{ .depth = 0, .held = @splat(false) };

    fn close(scopes: *Scopes) void {
        assert(scopes.depth <= brace.nest_depth_max);

        scopes.depth -|= 1;
    }

    fn open(scopes: *Scopes, template: bool) void {
        assert(scopes.depth <= brace.nest_depth_max);

        if (scopes.depth == brace.nest_depth_max) return;

        scopes.held[scopes.depth] = template;
        scopes.depth += 1;
    }

    fn templated(scopes: *const Scopes) bool {
        assert(scopes.depth <= brace.nest_depth_max);

        return scopes.depth > 0 and scopes.held[scopes.depth - 1];
    }

    fn valued(scopes: *const Scopes) bool {
        assert(scopes.depth <= brace.nest_depth_max);

        return scopes.depth > 0 and !scopes.held[scopes.depth - 1];
    }
};

const alias_marks: []const []const u8 = &.{ ".", "?.", "<", ">", "," };
const ampersand_words: []const []const u8 = &.{"&"};
const argument_head_max: u32 = 8;
const arm_bar_max: u32 = 256;
const arrow_body_names: []const []const u8 = &.{ "!", "super", "this" };

const arrow_heads: []const []const u8 = &.{
    "async",
    "await",
    "case",
    "default",
    "delete",
    "do",
    "else",
    "new",
    "return",
    "typeof",
    "void",
    "yield",
};

const binary_equalities: []const []const u8 = &.{ "!=", "!==", "==", "===" };
const binary_operator_max: u32 = 64;
const binary_products: []const []const u8 = &.{ "%", "*", "/" };
const binary_links: []const []const u8 = &.{ "&&", "*", "+", "-", "??", "||" };

const binary_ranks: []const struct { []const u8, u32 } = &.{
    .{ "!=", 7 },
    .{ "!==", 7 },
    .{ "%", 11 },
    .{ "&", 6 },
    .{ "&&", 3 },
    .{ "*", 11 },
    .{ "+", 10 },
    .{ "-", 10 },
    .{ "/", 11 },
    .{ "<<", 9 },
    .{ "<=", 8 },
    .{ "==", 7 },
    .{ "===", 7 },
    .{ ">=", 8 },
    .{ ">>", 9 },
    .{ ">>>", 9 },
    .{ "??", 1 },
    .{ "^", 5 },
    .{ "in", 8 },
    .{ "instanceof", 8 },
    .{ "|", 4 },
    .{ "||", 2 },
};

const binary_stops: []const []const u8 = &.{
    "%=",
    "&&=",
    "*=",
    ",",
    "+=",
    "-=",
    "/=",
    ":",
    ";",
    "=",
    "=>",
    "?",
    "??=",
    "case",
    "return",
    "throw",
    "||=",
};

const bitwise_marks: []const []const u8 = &.{ ".", "?.", "|", "&", "^", "!", "~" };
const bitwise_operators: []const []const u8 = &.{ "&", "^", "|" };
const bitwise_scan_max: u32 = 64;
const bitwise_unaries: []const []const u8 = &.{ "!", "~", "-", "+", "typeof", "void" };
const cast_words: []const []const u8 = &.{ "as", "satisfies" };
const branch_align_columns: u32 = 2;
const chain_link_max: u32 = 32;
const clause_word_bodies: []const []const u8 = &.{ "do", "else" };
const chain_scan_max: u32 = 512;
const compare_rank: u32 = 8;
const compare_scan_max: u32 = 64;
const header_scan_max: u32 = 64;
const hug_head_scan_max: u32 = 32;
const hugged_heads: []const []const u8 = &.{ "async", "function" };
const logical_words: []const []const u8 = &.{ "&&", "||", "??" };
const member_prefix_max: u32 = 4;
const member_prefixes: []const []const u8 = &.{ "!", "await", "delete", "typeof", "void" };
const member_property_stops: []const []const u8 = &.{ ",", ";", "=>", "=" };

const member_type_words: []const []const u8 = &.{
    "as",
    "extends",
    "implements",
    "infer",
    "is",
    "keyof",
    "satisfies",
};

const operand_leads: []const []const u8 = &.{
    "!=",
    "%",
    "&",
    "&&",
    "*",
    "+",
    "-",
    "/",
    "<<",
    "<=",
    "==",
    ">=",
    ">>",
    "^",
    "as",
    "||",
};

const operand_scan_max: u32 = 1024;

const operand_stop_marks: []const []const u8 = &.{
    "#",
    "%=",
    "&=",
    "*=",
    "+=",
    ",",
    "->",
    "-=",
    "/=",
    ":",
    ";",
    "<<=",
    "=",
    "=>",
    ">>=",
    "^=",
};

const operand_stop_words: []const []const u8 = &.{
    "break",
    "const",
    "continue",
    "else",
    "enum",
    "fn",
    "for",
    "if",
    "impl",
    "in",
    "let",
    "loop",
    "match",
    "mod",
    "return",
    "static",
    "struct",
    "trait",
    "type",
    "use",
    "where",
    "while",
};

const postfix_words: []const []const u8 = &.{ "++", "--" };
const shift_rank: u32 = 9;
const shift_width_max: u32 = 3;
const bar_columns: u32 = 2;

const field_words: []const []const u8 = &.{
    "abstract",
    "declare",
    "override",
    "private",
    "protected",
    "public",
    "readonly",
    "static",
};

const narrow_modifier_words: []const []const u8 = &.{
    "abstract",
    "accessor",
    "declare",
    "override",
    "private",
    "protected",
    "public",
    "readonly",
    "static",
};

const tight_after: []const []const u8 = &.{ "!", "#", "(", "...", "?.", "@", "~" };
const tight_before: []const []const u8 = &.{ "!", ")", ",", "--", ".", ";", "?.", "]" };
const union_bars_scan_max: u32 = 8192;
pub const union_member_max: usize = 512;
const union_scan_max: u32 = 1024;
const statement_unaries: []const []const u8 = &.{ "delete", "typeof", "void" };

const wrapped_operators: []const []const u8 = &.{
    "!=",
    "!==",
    "%",
    "&&",
    "*",
    "+",
    "-",
    "/",
    "<=",
    "==",
    "===",
    ">=",
    "??",
    "in",
    "instanceof",
    "||",
};

const wrapped_refused: []const []const u8 = &.{ "=", "=>", "?", "as", "satisfies" };
const wrapped_words: []const []const u8 = &.{ "return", "throw" };
const wrapping_comment_max: u32 = 4;
const wrapping_words: []const []const u8 = &.{ "super", "this" };

fn closes_angles(text: []const u8) bool {
    if (text.len == 0) return false;

    for (text) |byte| {
        if (byte != '>') return false;
    }

    assert(text[0] == '>');

    return true;
}

fn words_contain(words: []const []const u8, text: []const u8) bool {
    assert(words.len <= std.math.maxInt(u16));
    assert(text.len <= std.math.maxInt(u32));

    for (words) |word| {
        if (walk.text_eql(word, text)) return true;
    }

    return false;
}

pub fn angled_object(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.angle_objects) return false;
    if (emitter.brackets.angles_at(open) == 0) return false;

    const before = emit.back_of(emitter, open) orelse return false;
    const marked = emitter.tokens[before].text(emitter.source);
    const angled = walk.text_is(marked, "<") or walk.text_is(marked, ",");
    if (!angled) return false;

    var scan = open;

    for (0..union_scan_max) |_| {
        const held = emit.back_of(emitter, scan) orelse return true;
        const kind = emitter.tokens[held].kind;
        if (kind == .block_start) return true;
        if (kind == .block_end) return true;
        if (kind == .comment) return true;
        if (kind.eql(.{ .punctuation = .semicolon })) return true;
        if (kind.eql(.{ .punctuation = .paren_close })) return false;

        scan = held;
    }

    return false;
}

pub fn arm_barred(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.arm_bars) return null;
    if (!walk.text_is(emitter.tokens[position].text(emitter.source), "|")) return null;

    const held = emit.back_of(emitter, position) orelse return null;
    const kind_held = emitter.tokens[held].kind;
    const operand = walk.ends_operand(kind_held) or kind_held == .block_end;
    if (!operand) return null;

    var depth: i32 = 0;
    var scan = position + 1;

    for (0..arm_bar_max) |_| {
        if (scan >= emitter.count) return null;

        const token = emitter.tokens[scan];
        const kind = token.kind;

        if (walk.is_open(kind)) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            if (depth == 0) {
                if (!kind.eql(.{ .punctuation = .paren_close })) return null;
            }

            depth -= 1;
        } else if (depth <= 0) {
            const arrowed = walk.text_is(token.text(emitter.source), "=>");
            const bound = kind.eql(.{ .punctuation = .assign }) and arm_letted(emitter, position);
            const reached = arrowed or bound;
            if (reached) return arm_barred_level(emitter, depth);
            if (kind.eql(.{ .punctuation = .comma })) return null;
            if (kind.eql(.{ .punctuation = .semicolon })) return null;
        } else {}

        scan += 1;
    }

    return null;
}

fn arm_barred_level(emitter: *const Emitter, depth: i32) ?u32 {
    assert(depth <= 0);
    assert(emitter.depth <= brace.nest_depth_max);

    const lowered: u32 = @abs(depth);
    if (lowered > emitter.levels) return null;
    assert(emitter.levels - lowered < std.math.maxInt(u32));

    return emitter.levels - lowered;
}

fn arm_letted(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var depth: u32 = 0;
    var scan = position;

    for (0..arm_bar_max) |_| {
        const held = emit.back_of(emitter, scan) orelse return false;
        const kind = emitter.tokens[held].kind;

        assert(held < scan);

        if (walk.is_close(kind)) {
            depth += 1;
        } else if (walk.is_open(kind)) {
            if (depth == 0) return false;

            depth -= 1;
        } else if (depth == 0) {
            if (walk.text_is(emitter.tokens[held].text(emitter.source), "let")) return true;
            if (kind.eql(.{ .punctuation = .semicolon })) return false;
        } else {}

        scan = held;
    }

    return false;
}

pub fn assign_level(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (!emitter.policy.operand_levels) return null;
    if (!emitter.continued) return null;

    const previous = line.coded(emitter) orelse return null;

    assert(previous < emitter.count);

    if (!emitter.tokens[previous].is_punctuation(.assign)) return null;
    if (lead.leveled_at(emitter, previous) != emitter.printed) return null;
    assert(emitter.printed + 1 < std.math.maxInt(u32));

    return emitter.printed + 1;
}

pub fn binary_assigned(emitter: *const Emitter, previous: u32) bool {
    assert(previous < emitter.count);

    const head, const stop = binary_assigns(emitter, previous) orelse return false;
    return !binary_parted(emitter, head, stop);
}

fn binary_assigns(emitter: *const Emitter, previous: u32) ?struct { u32, u32 } {
    assert(previous < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.binary_parts) return null;
    if (!emitter.tokens[previous].is_punctuation(.assign)) return null;
    if (list.assign_owed(emitter)) return null;
    if (!edge.inside_a_body(emitter)) return null;
    if (binary_inline(emitter, previous)) return null;
    if (own.enum_valued(emitter, previous)) return null;

    const head, const stop = binary_valued(emitter, previous) orelse return null;

    if (binary_inlined(emitter, stop)) return null;
    if (!binary_lined(emitter, head, stop)) return null;
    return .{ head, stop };
}

pub fn binary_broken(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < emitter.count);

    if (emitter.tokens[position].length == 0) return false;
    if (shifted_pair(emitter, previous, position)) return false;

    const head, const stop = binary_owned(emitter, previous) orelse return false;

    assert(head <= stop);

    if (binary_parted(emitter, head, stop)) return false;
    if (wrap.nest_bodied(emitter, previous, head, stop)) return true;
    return binary_wide(emitter, head, stop);
}

pub fn binary_carried(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.chain_simples) return null;

    const previous = line.coded(emitter) orelse return null;
    if (!wrapping_operator(emitter, previous)) return null;

    const head, const stop = binary_run(emitter, previous) orelse return null;

    const tested = binary_carried_tested(emitter, previous) +
        call.binary_subrun_step(emitter, previous, head, stop);

    if (element_level(emitter, head)) |level| {
        assert(level + tested < std.math.maxInt(u32));

        return level + tested;
    }

    if (list.spreads(emitter)) {
        const frame = line.frame(emitter);

        if (line.at(emitter, head)) |found| {
            if (found.start - 1 < frame.open) return frame.inset;
        }
    }

    const level = lead.leveled_at(emitter, head) orelse return null;
    const looked = emitter.depth > 0 and list.bracket_lookup(emitter, line.frame(emitter).open);
    const returned = level + @intFromBool(binary_stated(emitter, head) or looked);

    assert(returned < std.math.maxInt(u32));

    return returned;
}

pub fn binary_stated(emitter: *const Emitter, head: u32) bool {
    assert(head < emitter.count);
    assert(emitter.policy.chain_simples);

    const statement = edge.statement_head(emitter, head) orelse return false;

    assert(statement <= head);

    if (statement != head) return false;

    const before = comment.back(emitter, head) orelse return true;
    const token = emitter.tokens[before];
    if (token.is_punctuation(.semicolon)) return true;
    if (token.kind == .block_end) return true;
    if (token.kind != .block_start) return false;
    return !emit.roled(emitter, before, brace.role_jsx_hole);
}

fn binary_carried_tested(emitter: *const Emitter, previous: u32) u32 {
    assert(previous < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!sole.binary_tested(emitter, previous)) return 0;
    if (!sole.binary_test_indents(emitter, previous)) return 0;
    return 1;
}

fn binary_held(emitter: *const Emitter, previous: u32, spread: bool) ?struct { u32, u32 } {
    assert(previous < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.binary_parts) return null;

    const owns = list.assign_held(emitter, previous) or body_owned(emitter, previous);

    const settled = !spread and owns and !binary_nested(emitter, previous) and
        !body_grouped(emitter) and !paren_run(emitter);

    if (settled) return null;
    if (binary_inline(emitter, previous)) return null;
    if (!wrapping_operator(emitter, previous)) return null;
    if (binary_nested(emitter, previous)) return call.binary_operand(emitter, previous);

    const head, const stop = binary_run(emitter, previous) orelse return null;
    const seat = binary_seat(emitter, head, stop) orelse return null;

    if (binary_inlined(emitter, stop)) return null;
    if (own.enum_valued(emitter, seat)) return null;

    const wrapped_last = emitter.wraps_owed == 0 and
        words_contain(wrapped_words, emitter.tokens[seat].text(emitter.source));

    if (wrapped_last) return null;
    if (!binary_spine(emitter, head, stop, previous)) return null;
    return .{ head, stop };
}

fn binary_inside(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    var depth: u32 = 0;
    var scan = open + 1;

    while (scan < close) : (scan += 1) {
        const kind = emitter.tokens[scan].kind;

        if (walk.is_open(kind)) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            depth -|= 1;
        } else if (depth == 0) {
            if (binary_rank(emitter, scan) != null) return true;
        } else {}
    }

    return false;
}

pub fn binary_joined(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < emitter.count);

    if (!emitter.policy.binary_parts) return false;
    if (!wrapping_operator(emitter, previous)) return false;

    const from = emitter.tokens[previous].end();
    const to = emitter.tokens[position].offset;
    if (body.parted_by(emitter, from, to) > 0) return false;
    if (binary_nested(emitter, previous)) return !binary_broken(emitter, position, previous);

    const head, const stop = binary_run(emitter, previous) orelse return false;
    return !binary_spine(emitter, head, stop, previous);
}

pub fn binary_level(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    const held = line.coded(emitter) orelse return null;

    assert(held < emitter.count);

    const bodied: u32 = @intFromBool(bodied_owed(emitter, position));
    if (binary_leveled(emitter, held)) return binary_level_run(emitter, held, bodied);

    const head, _ = binary_assigns(emitter, held) orelse return null;

    _ = head;

    const returned = item_level(emitter) + 1;

    assert(returned < std.math.maxInt(u32));

    return returned;
}

fn binary_level_run(emitter: *const Emitter, held: u32, bodied: u32) u32 {
    assert(held < emitter.count);
    assert(bodied <= 1);

    const argued = binary_argued(emitter, held);
    const parenthesized = binary_parenthesized(emitter, held);
    const conditioned = binary_conditioned(emitter, held);
    const based = binary_level_based(emitter, held, argued, parenthesized, conditioned);
    const later = wrap.binary_trailing(emitter, held);
    const sequenced = bind.sequence_wrapped_item(emitter, held);
    const nest_blocked = parenthesized and !later;
    const nest_active = !nest_blocked and !sequenced and binary_nested(emitter, held);
    const nested: u32 = @intFromBool(nest_active) * (1 + wrap.binary_ancestors(emitter, held));
    const testing = binary_level_testing(emitter, held, nested, parenthesized, argued, conditioned);
    const continued = sole.run_continued(emitter, held);
    const tested: u32 = @intFromBool(testing and !continued);
    const rooted = binary_level_rooted(emitter, held, based, nested);
    const stepped = binary_level_stepped(emitter, held, parenthesized);
    const listed = argued and !binary_level_tested_gap(emitter, held);
    const level = rooted + bodied + nested + tested + @intFromBool(stepped) + @intFromBool(listed);
    const concluded = testing and continued;
    if (concluded) return @max(level, emitter.printed);
    assert(level < std.math.maxInt(u32));

    return level;
}

fn binary_level_based(
    emitter: *const Emitter,
    held: u32,
    argued: bool,
    parenthesized: bool,
    conditioned: bool,
) u32 {
    assert(held < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (argued) {
        if (binary_based(emitter, held)) |based| return based;
    }

    const headless = parenthesized and emitter.indent < emitter.printed and
        binary_headless(emitter, held);

    if (headless) return emitter.indent;

    const headed = parenthesized or conditioned;

    if (headed) {
        if (binary_headed_level(emitter, held)) |level| return level;
    }

    if (tern.branch_run_seat(emitter, held)) |level| return level;
    if (wrap.paired_seat(emitter, held)) |level| return level;
    if (wrap.operand_chain_level(emitter, held)) |level| return level;
    return item_level(emitter);
}

fn binary_level_testing(
    emitter: *const Emitter,
    held: u32,
    nested: u32,
    parenthesized: bool,
    argued: bool,
    conditioned: bool,
) bool {
    assert(held < emitter.count);
    assert(nested <= core.wrap_depth_max + 1);

    if (nested != 0) return false;
    if (parenthesized) return false;
    if (argued) return false;
    if (conditioned) return false;
    if (binary_armed(emitter, held)) return false;

    const tested = sole.binary_tested(emitter, held) and sole.binary_test_indents(emitter, held);
    return tested or tern.binary_branched(emitter, held);
}

fn binary_level_tested_gap(emitter: *const Emitter, held: u32) bool {
    assert(held < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    return sole.binary_tested(emitter, held) and !sole.binary_test_indents(emitter, held);
}

fn binary_level_rooted(emitter: *const Emitter, held: u32, based: u32, nested: u32) u32 {
    assert(held < emitter.count);
    assert(emitter.wraps_owed <= core.wrap_depth_max);
    assert(based < std.math.maxInt(u32));

    const inset = call.operand_inset(emitter, held);

    if (nested >= 1) {
        const returned = inset + @min(based, emitter.wraps_indent[wrap.run_top(emitter)]);

        assert(returned < std.math.maxInt(u32));

        return returned;
    }

    assert(inset + based < std.math.maxInt(u32));

    return inset + based;
}

fn binary_level_stepped(emitter: *const Emitter, held: u32, parenthesized: bool) bool {
    assert(held < emitter.count);
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    if (!parenthesized) return false;
    if (binary_level_tested_gap(emitter, held)) return false;

    const armed = paren_run(emitter) and emitter.wraps_armed[wrap.run_top(emitter)];
    return !armed;
}

fn binary_leveled(emitter: *const Emitter, previous: u32) bool {
    assert(previous < emitter.count);

    const owned = binary_owned(emitter, previous);
    return owned != null;
}

pub fn binary_operand_parted(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < emitter.count);

    if (!emitter.policy.binary_lines) return false;
    if (emitter.tokens[position].kind == .comment) return false;
    if (!wrapping_operator(emitter, previous)) return false;
    if (call.logical_operator(emitter, previous)) return false;

    const before = emit.back_of(emitter, previous) orelse return false;
    const kind = emitter.tokens[before].kind;

    const closed = kind.eql(.{ .punctuation = .bracket_close }) or
        kind.eql(.{ .punctuation = .paren_close });

    if (!closed) return false;
    if (operand_tailed(emitter, before, previous)) return false;

    const open = emitter.brackets.open_of(before) orelse return false;
    return open < emitter.line_first;
}

pub fn binary_owned(emitter: *const Emitter, previous: u32) ?struct { u32, u32 } {
    assert(previous < emitter.count);

    const found = binary_held(emitter, previous, false);

    if (found) |held| assert(held[0] <= held[1]);

    return found;
}

pub fn binary_rank(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!wrapping_operator(emitter, position)) return null;
    if (shift_width(emitter, position) >= 2) return shift_rank;
    if (shifted_pair(emitter, position -% 1, position)) return null;
    if (comparing(emitter, position)) return compare_rank;

    const text = emitter.tokens[position].text(emitter.source);

    for (binary_ranks) |pair| {
        if (walk.text_eql(pair[0], text)) return pair[1];
    }

    return null;
}

fn bitwise_aliased(emitter: *const Emitter, equals: u32) bool {
    assert(equals < emitter.count);
    assert(emitter.tokens[equals].is_punctuation(.assign));

    var scan = equals;

    for (0..bitwise_scan_max) |_| {
        const held = emit.back_of(emitter, scan) orelse return false;
        const token = emitter.tokens[held];
        const text = token.text(emitter.source);
        if (walk.text_is(text, "type")) return true;

        if (closes_angles(text)) {
            scan = list.opening(emitter, held, @intCast(text.len)) orelse return false;

            continue;
        }

        if (!token.ends_a_value()) {
            if (!words_contain(alias_marks, text)) return false;
        }

        scan = held;
    }

    return false;
}

fn bitwise_argued(emitter: *const Emitter, held: u32) bool {
    assert(held < emitter.count);
    assert(walk.is_open(emitter.tokens[held].kind));

    const unaried = if (emit.back_of(emitter, held)) |found|
        words_contain(bitwise_unaries, emitter.tokens[found].text(emitter.source))
    else
        false;

    if (!emitter.tokens[held].is_punctuation(.paren_open)) return false;
    if (list.calling(emitter, held)) return true;
    if (split.headed(emitter, held)) return true;
    return unaried;
}

fn bitwise_untyped(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.brackets.angles_at(position) == 0);

    const held = line.coding(emitter, position) orelse return false;
    if (emit.roled(emitter, held, brace.role_type)) return false;
    return !emit.roled(emitter, position, brace.role_type);
}

fn bitwise_valued(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.brackets.angles_at(position) == 0);

    var scan = position;

    for (0..bitwise_scan_max) |_| {
        const held = emit.back_of(emitter, scan) orelse return false;
        const token = emitter.tokens[held];

        if (walk.is_close(token.kind)) {
            if (emitter.brackets.open_of(held)) |open| {
                scan = open;

                continue;
            }
        }

        if (walk.is_open(token.kind)) return bitwise_argued(emitter, held);
        if (walk.is_close(token.kind)) return false;
        if (token.kind == .block_end) return false;

        if (token.is_punctuation(.comma)) {
            scan = held;

            continue;
        }

        const text = token.text(emitter.source);
        if (words_contain(wrapped_words, text)) return true;
        if (words_contain(cast_words, text)) return false;
        if (token.is_punctuation(.assign)) return !bitwise_aliased(emitter, held);

        const logical = words_contain(logical_words, text);

        if (!token.ends_a_value()) {
            if (!logical) {
                if (!words_contain(bitwise_marks, text)) return false;
            }
        }

        scan = held;
    }

    return false;
}

fn bodied_owed(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    if (emitter.owns == 0) return false;

    for (emitter.wrapped[0..emitter.wraps_owed]) |held| {
        if (held.wrap != .bodied) continue;
        if (position > held.close) continue;
        if (held.depth != emitter.depth) continue;

        if (emitter.depth > 0) {
            if (line.frame(emitter).kind != .block_start) continue;
        }

        if (held.start < emitter.line_before) continue;
        if (held.start >= position) continue;
        return true;
    }

    return false;
}

fn branch_seated(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.ternary_levels) return null;
    if (!wrapping_ternary(emitter, position)) return null;

    var depth: u32 = 0;
    var scan = position;

    for (0..chain_scan_max) |_| {
        if (scan == 0) return null;

        scan -= 1;

        if (bind.hole_open(emitter, scan)) |hole| {
            scan = hole;

            continue;
        }

        const kind = emitter.tokens[scan].kind;
        const closed = walk.is_close(kind) or kind == .block_end;
        const opened = walk.is_open(kind) or kind == .block_start;

        if (closed) {
            depth += 1;
        } else if (opened) {
            if (depth == 0) return null;

            depth -= 1;
        } else if (depth == 0) {
            if (branch_seat(emitter, scan)) return scan;
        } else {}
    }

    return null;
}

pub fn chain_broken(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.chain_groups) return false;
    if (!jsx.chain_split(emitter, position)) return false;

    if (!edge.inside_a_body(emitter)) {
        if (!tmpl.holed(emitter)) return false;
    }

    return chain_expanded(emitter, position);
}

pub fn chain_flatted(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.chain_simples) return false;
    if (!emit.is_dot(emitter, position)) return false;
    if (!edge.inside_a_body(emitter)) return false;

    const head = link.chain_start(emitter, position) orelse return false;
    const stop = link.chain_stop(emitter, head) orelse return false;
    var links: [chain_link_max]u32 = @splat(0);
    const count = link.chain_groups(emitter, head, stop, &links);
    const merges = chain_merges(emitter, head, &links, count);
    const cutoff: u32 = if (merges) 3 else 2;

    assert(count <= chain_link_max);

    if (count >= cutoff) {
        const from: usize = @intFromBool(merges);
        if (std.mem.findScalar(u32, links[from..count], position) == null) return true;
        if (call.chain_composed(emitter, head, stop)) return false;
    }

    if (count < cutoff) return true;
    return !chain_overflows(emitter, head, stop);
}

pub fn chain_level(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.line_before <= emitter.count);

    if (chain_orphan(emitter, position, emitter.line_before)) |head| {
        return lead.leveled_at(emitter, head);
    }

    if (emit.is_dot(emitter, position)) {
        if (!emit.is_dot(emitter, emitter.line_before)) {
            if (branch_seated(emitter, position)) |branch| {
                if (tern.ternary_level(emitter, branch)) |level| return level;
            }
        }
    }

    return chain_nested(emitter, position);
}

fn chain_lonely(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.chain_groups) return false;

    const head = link.chain_start(emitter, position) orelse return false;
    const stop = link.chain_stop(emitter, head) orelse return false;
    var links: [chain_link_max]u32 = @splat(0);
    const count = link.chain_groups(emitter, head, stop, &links);
    const merges = chain_merges(emitter, head, &links, count);
    const cutoff: u32 = if (merges) 3 else 2;

    assert(count <= chain_link_max);

    return count < cutoff;
}

fn chain_nested(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.line_before <= emitter.count);

    if (!emitter.policy.operand_levels) return null;
    if (!emit.is_dot(emitter, position)) return null;
    if (emit.ranges(emitter, position)) return null;

    const previous = line.coded(emitter) orelse return null;
    if (!walk.is_close(emitter.tokens[previous].kind)) return null;

    const head = wide.chain_head(emitter, position);
    if (head >= emitter.line_before) return null;
    if (emitter.brackets.open_of(previous) != head) return null;
    if (!emitter.tokens[head].is_punctuation(.paren_open)) return null;

    assert(head < previous);

    if (emit.back_of(emitter, head)) |held| {
        if (walk.ends_operand(emitter.tokens[held].kind)) return null;
    }

    if (wide.element_count(emitter, head, previous) > 1) return null;
    if (!binary_inside(emitter, head, previous)) return null;

    const level = lead.leveled_at(emitter, head) orelse return null;
    assert(level + 1 < std.math.maxInt(u32));

    return level + 1;
}

fn chain_orphan(emitter: *const Emitter, position: u32, led: u32) ?u32 {
    assert(position < emitter.count);
    assert(led <= emitter.count);

    if (!emitter.policy.operand_levels) return null;
    if (!emit.is_dot(emitter, position)) return null;
    if (emit.ranges(emitter, position)) return null;

    const previous = line.coded(emitter) orelse return null;
    if (emitter.tokens[previous].kind != .block_end) return null;
    if (chain_lonely(emitter, position)) return null;
    if (link.chain_brace_lonely(emitter, position)) return null;

    const head = wide.chain_head(emitter, position);
    if (head < led) return head;
    return null;
}

pub fn chain_orphaned(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    const head = chain_orphan(emitter, position, emitter.line_first);

    if (head) |held| assert(held < emitter.line_first);

    return head != null;
}

pub fn chain_parts(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < emitter.count);

    if (!emitter.policy.chain_groups) return false;
    if (!jsx.chain_split(emitter, position)) return false;

    const head = link.chain_start(emitter, position) orelse return false;
    const stop = link.chain_stop(emitter, head) orelse return false;
    const composed = call.chain_composed(emitter, head, stop);

    if (!composed) {
        if (!emitter.policy.chain_simples) {
            const from = emitter.tokens[head].offset;
            const to = emitter.tokens[stop].end();
            if (body.parted_by(emitter, from, to) > 0) return false;
        }
    }

    return chain_parts_linked(emitter, position, head, stop, composed);
}

fn chain_parts_linked(
    emitter: *const Emitter,
    position: u32,
    head: u32,
    stop: u32,
    composed: bool,
) bool {
    assert(head <= position);
    assert(stop < emitter.count);

    var links: [chain_link_max]u32 = @splat(0);
    const count = link.chain_groups(emitter, head, stop, &links);
    const merges = chain_merges(emitter, head, &links, count);
    const cutoff: u32 = if (merges) 3 else 2;
    const from: usize = @intFromBool(merges);
    const linked = std.mem.findScalar(u32, links[from..count], position) != null;

    if (linked) {
        if (link.chain_suffixed(emitter, head, stop)) return true;
    }

    if (count < cutoff) return false;
    if (!linked) return false;
    if (chain_calls(emitter, head, stop) < 2) return false;
    if (composed) return true;
    return chain_wide(emitter, head, stop, position == links[from]);
}

fn comparing(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    if (core.memo_found(emitter, .comparing, position, 0)) |answer| return answer == 1;

    const held = comparing_scanned(emitter, position);

    core.memo_store(emitter, .comparing, position, 0, @intFromBool(held));

    return held;
}

fn comparing_scanned(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    if (emitter.brackets.angles_at(position) > 0) return false;
    if (shift_width(emitter, position) >= 2) return false;

    const text = emitter.tokens[position].text(emitter.source);
    if (walk.text_is(text, ">")) return true;
    if (!walk.text_is(text, "<")) return false;

    const slashed = if (emit.ahead_of(emitter, position)) |held|
        std.mem.startsWith(u8, emitter.tokens[held].text(emitter.source), "/") and
            emitter.tokens[held].offset == emitter.tokens[position].end()
    else
        false;

    if (emit.roled(emitter, position, brace.role_spaced)) {
        if (!slashed) return true;
    }

    return comparing_scan(emitter, position);
}

fn comparing_scan(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(walk.text_is(emitter.tokens[position].text(emitter.source), "<"));

    var depth: u32 = 0;
    var scan = position;

    for (0..compare_scan_max) |_| {
        const held = emit.ahead_of(emitter, scan) orelse return true;
        const kind = emitter.tokens[held].kind;

        if (tmpl.template_body(emitter, held)) |end| {
            scan = end;

            continue;
        }

        const opens = walk.is_open(kind) or kind == .block_start;

        if (opens) {
            scan = join.closing_of(emitter, held) orelse return true;

            continue;
        }

        const closes = walk.is_close(kind) or kind == .block_end or
            emitter.tokens[held].is_punctuation(.semicolon);

        if (closes) return true;

        const spelled = emitter.tokens[held].text(emitter.source);

        if (walk.text_is(spelled, "<")) {
            depth += 1;
        } else if (closes_angles(spelled)) {
            if (depth == 0) return false;

            depth -|= 1;
        } else {}

        scan = held;
    }

    return true;
}

pub fn element_level(emitter: *const Emitter, head: u32) ?u32 {
    assert(head < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (!list.spreads(emitter)) return null;

    const frame = emitter.nest[emitter.depth - 1];
    const before = emit.back_of(emitter, head) orelse return null;
    if (before == frame.open) return frame.inset;
    if (!emitter.tokens[before].is_punctuation(.comma)) return null;

    var depth: u32 = 0;
    var scan = frame.open + 1;

    while (scan < before) : (scan += 1) {
        const kind = emitter.tokens[scan].kind;
        const opens = walk.is_open(kind) or kind == .block_start or bind.spans_open(emitter, scan);
        const closes = walk.is_close(kind) or kind == .block_end;

        if (opens) {
            depth += 1;
        } else if (closes) {
            depth -|= 1;
        } else {}
    }

    if (depth == 0) return frame.inset;
    return null;
}

fn grouping_paren(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    const blocked = !emitter.tokens[open].is_punctuation(.paren_open) or
        list.calling(emitter, open);

    if (blocked) return false;

    if (emit.back_of(emitter, open)) |held| {
        if (line.word_is(emitter, held, emitter.policy.header_words)) return false;
    }

    var depth: u32 = 0;
    var found = false;
    var scan = open + 1;

    while (scan < close) {
        const kind = emitter.tokens[scan].kind;
        const opens = walk.is_open(kind) or kind == .block_start;
        const closes = walk.is_close(kind) or kind == .block_end;

        if (opens) {
            depth += 1;
        } else if (closes) {
            depth -|= 1;
        } else if (depth == 0) {
            const text = emitter.tokens[scan].text(emitter.source);
            const stops = walk.text_is(text, ",") or walk.text_is(text, "=>");
            if (stops) return false;

            const matched = words_contain(binary_links, text) or
                binary_rank(emitter, scan) != null or
                (walk.text_is(text, "?") and !tern.optional(emitter, scan));

            found = found or matched;
        } else {}

        scan += 1;
    }

    return found;
}

pub fn header_bodied(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.chain_simples) return null;
    if (!emitter.policy.header_parens) return null;

    const previous = line.coded(emitter) orelse return null;
    if (clause.else_bodied(emitter, position, previous)) |level| return level;
    if (!emitter.tokens[previous].kind.eql(.{ .punctuation = .paren_close })) return null;
    if (emitter.tokens[position].kind == .block_start) return null;

    const open = emitter.brackets.open_of(previous) orelse return null;
    if (!split.headed(emitter, open)) return null;

    const head = emit.word_before(emitter, open) orelse return null;
    const found = line.at(emitter, head) orelse return null;
    var led = found.level;

    if (emitter.bound_ring) |ring| {
        if (ring.start == found.start) led = ring.level;
    }

    assert(led + 1 < std.math.maxInt(u32));

    return led + 1;
}

pub fn header_broken(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < emitter.count);

    if (!emitter.policy.chain_simples) return false;
    if (!emitter.policy.header_parens) return false;
    if (!emitter.tokens[previous].kind.eql(.{ .punctuation = .paren_close })) return false;

    const kind = emitter.tokens[position].kind;
    if (kind == .block_start) return false;
    if (kind.eql(.{ .punctuation = .semicolon })) return false;

    const open = emitter.brackets.open_of(previous) orelse return false;
    if (!split.headed(emitter, open)) return false;
    if (emitter.line_first > open) return false;

    const end = call.valued_semicolon(emitter, position) orelse return false;
    return header_over(emitter, end, clause.bound(emitter, open, previous));
}

pub fn header_fitted(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < emitter.count);

    if (header_worded(emitter, position, previous)) return !header_wide(emitter, position);
    if (!header_headed(emitter, position, previous)) return false;
    return !header_broken(emitter, position, previous);
}

fn header_headed(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < emitter.count);

    if (!emitter.policy.chain_simples) return false;
    if (!emitter.policy.header_parens) return false;
    if (!emitter.tokens[previous].kind.eql(.{ .punctuation = .paren_close })) return false;

    const kind = emitter.tokens[position].kind;
    if (kind == .block_start) return false;
    if (kind.eql(.{ .punctuation = .semicolon })) return false;

    const open = emitter.brackets.open_of(previous) orelse return false;
    if (!split.headed(emitter, open)) return false;
    return emitter.line_first <= open;
}

pub fn header_lined(emitter: *const Emitter, open: u32) ?u32 {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (emitter.tokens[open].kind != .block_start) return null;

    var scan = open;

    for (0..header_scan_max) |_| {
        const held = emit.back_of(emitter, scan) orelse return null;
        const kind = emitter.tokens[held].kind;

        assert(held < scan);

        if (walk.is_close(kind)) {
            scan = emitter.brackets.open_of(held) orelse return null;

            continue;
        }

        if (walk.is_open(kind)) return null;
        if (line.word_is(emitter, held, emitter.policy.header_words)) return held;
        if (kind.eql(.{ .punctuation = .semicolon })) return null;
        if (line.word_is(emitter, held, emitter.policy.head_stops)) return null;

        scan = held;
    }

    return null;
}

fn header_worded(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < emitter.count);

    if (!emitter.policy.chain_simples) return false;
    if (!emitter.policy.header_parens) return false;

    const kind = emitter.tokens[position].kind;
    if (kind == .block_start) return false;
    if (kind.eql(.{ .punctuation = .semicolon })) return false;
    if (emitter.line_first != previous) return false;
    if (!line.word_is(emitter, previous, emitter.policy.body_words)) return false;

    const text = emitter.tokens[previous].text(emitter.source);
    return walk.text_is(text, "do") or walk.text_is(text, "else");
}

fn hug_broken_head(emitter: *const Emitter, open: u32, from: u32, level: u32) ?u32 {
    assert(open < emitter.count);
    assert(emitter.tokens[open].is_punctuation(.paren_open));
    assert(from < emitter.count);
    assert(level < std.math.maxInt(u32));

    var scan = emit.back_of(emitter, open) orelse return null;

    for (0..hug_head_scan_max) |_| {
        const token = emitter.tokens[scan];

        if (walk.is_close(token.kind)) {
            const head = emitter.brackets.open_of(scan) orelse return null;
            if (head < from) return null;

            const width = level * emitter.options.indent_width +
                printed_columns(emitter, from, open);

            if (width > emitter.options.line_width) return scan;
            return null;
        }

        if (token.kind != .identifier) {
            if (!emit.is_dot(emitter, scan)) return null;
        }

        scan = emit.back_of(emitter, scan) orelse return null;
    }

    return null;
}

fn hug_concise(emitter: *const Emitter, before: u32, tail: u32, close: u32) bool {
    assert(before < tail);
    assert(tail < close);

    const kind = emitter.tokens[tail].kind;
    const bracket = emitter.tokens[tail].is_punctuation(.bracket_open);

    const numeric = if (join.closing_of(emitter, tail)) |held|
        list.numeric(emitter, tail, held)
    else
        false;

    const concise = bracket and numeric;
    const braced = bracket or kind == .block_start;
    const alike = braced and call.arguments_alike(emitter, before, tail, close);

    return concise or alike;
}

fn hug_fitted(emitter: *const Emitter, open: u32, close: u32, tail: u32) ?u32 {
    assert(open < tail);
    assert(tail < close);

    const end = spread_headline(emitter, tail, close);

    const led, const level = lead.spread(emitter, open) orelse
        .{ @min(emitter.line_first, open), emitter.printed };

    const from = hug_broken_head(emitter, open, led, level) orelse
        call.assign_angle_head(emitter, open, led, level) orelse led;

    const room = level * emitter.options.indent_width + printed_columns(emitter, from, end);
    const bodied = walk.text_is(emitter.tokens[end].text(emitter.source), "=>");

    if (bodied) {
        const whole = level * emitter.options.indent_width + printed_columns(emitter, from, close) +
            chain_widened(emitter, from, close);

        if (whole <= emitter.options.line_width) return null;
    }

    if (room <= emitter.options.line_width) return tail;
    return null;
}

fn headline_arrow(emitter: *const Emitter, scan: u32, close: u32) ?u32 {
    assert(scan < close);
    assert(close < emitter.count);

    if (!walk.text_is(emitter.tokens[scan].text(emitter.source), "=>")) return null;

    const opened = emit.ahead_of(emitter, scan) orelse return null;
    if (opened >= close) return null;
    if (emitter.tokens[opened].is_punctuation(.bracket_open)) return opened;
    if (arrow_body_grouped(emitter, opened, close)) return scan;
    return null;
}

fn indented(
    emitter: *Emitter,
    source: []const u8,
    at: u32,
    to: u32,
    tabbed: bool,
    width: u32,
) error{Overflow}!u32 {
    assert(at < to);
    assert(to <= source.len);
    assert(width < std.math.maxInt(u32));

    const byte = source[at];
    const blank = byte == '\n' or byte == ' ' or byte == '\t';
    const plain = !tabbed or !blank;

    if (plain) {
        try emitter.arena.push(source[at .. at + 1]);

        assert(at + 1 <= to);

        return at + 1;
    }

    var stop: u32 = at + @as(u32, @intFromBool(byte == '\n'));

    while (stop < to) {
        const spaced = source[stop] == ' ' or source[stop] == '\t';
        if (!spaced) break;

        stop += 1;
    }

    const ends = stop >= to or source[stop] == '\n';

    if (byte != '\n') {
        if (!ends) try emitter.arena.push(source[at..stop]);

        assert(stop <= to);

        return stop;
    }

    const lead_width = stream.prefix_width(source[at + 1 .. stop], width);

    try emitter.arena.push("\n");

    if (!ends) try padded(emitter.arena, lead_width);

    assert(stop <= to);

    return stop;
}

pub inline fn jsx_body(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);

    if (!emit.roled(emitter, position, brace.role_jsx)) return null;
    return tags.body_close(emitter, position);
}

pub fn line_opened(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);

    const found = line.at(emitter, position) orelse return null;

    assert(found.start > 0);

    return found.start - 1;
}

pub fn linked_operand(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < emitter.count);

    if (!emitter.policy.operand_levels) return false;

    const text = emitter.tokens[position].text(emitter.source);
    if (!words_contain(operand_leads, text)) return false;
    if (walk.text_is(text, "as")) return false;
    if (!emit.operand_at(emitter, previous)) return false;
    if (line.attributed(emitter, previous)) return false;

    const angled = emitter.brackets.angles_at(position) >
        emitter.brackets.angles_at(emitter.line_first);

    if (angled) return false;

    const led = emit.is_dot(emitter, emitter.line_first) or operator_led(emitter, position);
    if (!led) return false;
    return linked_run(emitter, position);
}

fn linked_run(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.line_first < emitter.count);

    var depth: i32 = 0;
    var scan = emitter.line_first;

    while (scan < position) : (scan += 1) {
        const kind = emitter.tokens[scan].kind;

        if (walk.is_open(kind)) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            depth -= 1;

            if (depth < 0) return false;
        } else {}
    }

    return depth == 0;
}

pub fn marked_callee(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!line.word_is(emitter, position, emitter.policy.callee_marks)) return false;
    if (!tern.optional(emitter, position)) return false;

    const name = emit.word_before(emitter, position) orelse return false;
    if (!wide.named(emitter, name)) return false;
    if (!walk.text_is(emitter.tokens[position].text(emitter.source), "?")) return true;
    return tern.typed_frame(emitter);
}

pub fn member_parted(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    if (!emitter.policy.chain_simples) return false;
    if (!emit.is_dot(emitter, position)) return false;
    if (link.member_grouped(emitter, position)) return false;

    const head = link.chain_start(emitter, position) orelse return false;
    const chained = link.chain_stop(emitter, head) orelse return false;
    const casted = link.member_casted(emitter, head, chained);
    const stop = casted orelse chained;
    const trimmed = link.member_trimmed(emitter, casted, stop);
    const early = link.member_last(emitter, head, trimmed) != position;

    if (early) {
        if (!link.member_early(emitter, head, trimmed, position)) return false;
    } else {
        if (emit.ahead_of(emitter, position) != trimmed) return false;
    }

    const before = emit.back_of(emitter, position) orelse return false;
    const bare = emitter.tokens[before].kind == .identifier;
    const plain = !early and before == head and bare and trimmed == stop;
    if (plain) return false;

    const object = member_parted_object(emitter, before);
    const named = link.member_named(emitter, head);
    const valued = named != null and member_parted_valued(emitter, stop);

    if (valued) {
        if (member_parted_called(emitter, object)) return false;
    }

    const defaulted = named != null and own.param_defaulted(emitter);

    const parted: MemberParted = .{
        .head = head,
        .dot = position,
        .stop = stop,
        .casted = casted,
        .named = named,
        .valued = valued,
        .defaulted = defaulted,
    };

    if (member_parted_refused(emitter, &parted)) return false;

    const measured = if (casted) |held|
        link.member_cast_end(emitter, held + 1, chained)
    else
        chained;

    if (early) return link.member_early_overflows(emitter, head, position, defaulted);

    if (link.member_early_led(emitter, head, position)) {
        return link.member_led_overflows(emitter, head, measured);
    }

    return link.member_overflows(emitter, head, position, measured, defaulted);
}

const MemberParted = struct {
    head: u32,
    dot: u32,
    stop: u32,
    casted: ?u32,
    named: ?u32,
    valued: bool,
    defaulted: bool,
};

fn member_parted_object(emitter: *const Emitter, before: u32) u32 {
    assert(before < emitter.count);
    assert(emitter.policy.chain_simples);

    if (!walk.text_is(emitter.tokens[before].text(emitter.source), "!")) return before;
    return emit.back_of(emitter, before) orelse before;
}

fn member_parted_valued(emitter: *const Emitter, stop: u32) bool {
    assert(stop < emitter.count);
    assert(emitter.policy.chain_simples);

    const held = emit.ahead_of(emitter, stop) orelse return true;
    if (emitter.tokens[held].is_punctuation(.comma)) return true;
    return emitter.tokens[held].is_punctuation(.semicolon);
}

fn member_parted_called(emitter: *const Emitter, object: u32) bool {
    assert(object < emitter.count);
    assert(emitter.policy.chain_simples);

    if (!emitter.tokens[object].is_punctuation(.paren_close)) return false;

    const open = emitter.brackets.open_of(object) orelse return false;
    if (!list.calling(emitter, open)) return false;
    return emit.ahead_of(emitter, open) != object;
}

fn member_parted_refused(emitter: *const Emitter, parted: *const MemberParted) bool {
    assert(parted.head <= parted.dot);
    assert(emitter.policy.chain_simples);

    const head = parted.head;
    const stop = parted.stop;
    const keyed = link.member_keyed(emitter, head, stop) != null or parted.defaulted;

    if (member_operand(emitter, head, stop)) return true;

    if (!keyed) {
        if (parted.casted == null) {
            const slight = !link.slight_looped(emitter, head) and
                member_slight(emitter, head, stop);

            if (slight) return true;
        }
    }

    if (parted.valued) {
        if (parted.named != null) {
            if (link.member_call_chain(emitter, head)) return true;
        }
    }

    if (member_typed(emitter, head, parted.dot)) return true;
    if (member_newed(emitter, head, parted.dot)) return true;
    if (parted.casted != null) return false;

    if (!parted.defaulted) {
        if (link.member_lefted(emitter, parted.named, stop, parted.dot)) return true;
    }

    return member_valued(emitter, head, stop);
}

pub fn opened_level(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.depth < 2) return null;

    const held = emitter.nest[emitter.depth - 2];
    if (held.spread == null) return null;
    if (position <= held.open) return null;

    const head = opened_head(emitter, held.open, position);

    if (opened_declared(emitter, held)) {
        if (emitter.line_first == head) return null;

        if (emitter.line_first < head) {
            assert(held.inset + 1 <= emitter.count);

            return held.inset + 1;
        }
    }

    if (emitter.line_first <= head) return held.inset;
    return null;
}

fn opened_declared(emitter: *const Emitter, held: Frame) bool {
    assert(held.open < emitter.count);
    assert(emitter.listed <= core.binder_depth_max);

    if (emitter.listed == 0) return false;
    if (emitter.binders[emitter.listed - 1].start <= held.open) return false;
    return comment.header_clauses(emitter, held.open);
}

fn opened_head(emitter: *const Emitter, open: u32, position: u32) u32 {
    assert(open < position);
    assert(position < emitter.count);

    var depth: u32 = 0;
    var scan = position;

    while (scan > open + 1) {
        scan -= 1;

        if (bind.hole_open(emitter, scan)) |hole| {
            assert(hole < scan);

            scan = hole;

            continue;
        }

        const kind = emitter.tokens[scan].kind;
        const closes = walk.is_close(kind) or kind == .block_end;
        const opens = walk.is_open(kind) or kind == .block_start;

        if (closes) {
            depth += 1;
        } else if (opens) {
            depth -|= 1;
        } else if (depth == 0) {
            if (emitter.tokens[scan].is_punctuation(.comma)) {
                assert(scan + 1 <= emitter.count);

                return scan + 1;
            }
        } else {}
    }

    assert(open + 1 <= emitter.count);

    return open + 1;
}

pub fn operand_level(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (!emitter.policy.operand_levels) return null;
    if (!words_contain(operand_leads, emitter.tokens[position].text(emitter.source))) return null;

    const previous = line.coded(emitter) orelse return null;
    if (!emit.operand_at(emitter, previous)) return null;
    if (line.attributed(emitter, previous)) return null;
    if (operand_flattened(emitter, position)) return null;

    const head = operand_run_head(emitter, position) orelse return null;

    assert(head < position);

    if (emit.back_of(emitter, head)) |held| {
        if (walk.text_is(emitter.tokens[held].text(emitter.source), ":")) return null;
    }

    if (element_level(emitter, head)) |level| {
        assert(level + 1 < std.math.maxInt(u32));

        return level + 1;
    }

    const level = lead.leveled_at(emitter, head) orelse return null;
    assert(level + 1 < std.math.maxInt(u32));

    return level + 1;
}

fn operand_orphan(emitter: *const Emitter, position: u32, previous: u32) ?bool {
    assert(position < emitter.count);
    assert(previous < emitter.count);

    if (!emitter.policy.operand_levels) return null;
    if (!words_contain(operand_leads, emitter.tokens[position].text(emitter.source))) return null;
    if (!emit.operand_at(emitter, previous)) return null;
    if (line.attributed(emitter, previous)) return null;
    if (operand_flattened(emitter, position)) return null;

    const head = operand_run_head(emitter, position) orelse return null;
    if (head >= emitter.line_first) return null;

    const nested = (lead.leveled_at(emitter, head) orelse return null) + 1;
    const spread = join.header_width(emitter, emitter.line_first, previous) orelse return null;
    const under = emitter.printed * emitter.options.indent_width;

    return under + spread > nested * emitter.options.indent_width;
}

fn operand_flattened(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const before = emit.back_of(emitter, position) orelse return false;
    if (emitter.tokens[before].kind != .block_end) return false;
    return join.flattened(emitter, before);
}

fn operand_run_head(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var head = position;
    var scan = position;

    for (0..operand_scan_max) |_| {
        const before = emit.back_of(emitter, scan) orelse break;

        assert(before < scan);

        if (walk.is_close(emitter.tokens[before].kind)) {
            scan = emitter.brackets.open_of(before) orelse return null;
            head = scan;

            continue;
        }

        if (operand_stops(emitter, before)) {
            const bound = chain_let(emitter, position, before) orelse break;

            scan = bound;
            head = bound;

            continue;
        }

        scan = before;
        head = before;
    }

    if (head < position) return head;
    return null;
}

fn chain_let(emitter: *const Emitter, position: u32, equals: u32) ?u32 {
    assert(equals < position);
    assert(position < emitter.count);

    if (!emitter.policy.chain_lets) return null;
    if (!walk.text_is(emitter.tokens[equals].text(emitter.source), "=")) return null;
    if (!chain_anded(emitter, position)) return null;

    var scan = equals;

    for (0..operand_scan_max) |_| {
        const before = emit.back_of(emitter, scan) orelse return null;
        const token = emitter.tokens[before];
        const closes = walk.is_close(token.kind) or token.kind == .block_end;

        assert(before < scan);

        if (closes) {
            scan = emitter.brackets.open_of(before) orelse return null;

            continue;
        }

        if (token.kind == .block_start) return null;
        if (token.is_punctuation(.semicolon)) return null;

        const text = token.text(emitter.source);
        if (walk.text_is(text, "=")) return null;
        if (walk.text_is(text, "=>")) return null;

        if (!walk.text_is(text, "let")) {
            scan = before;

            continue;
        }

        const opener = emit.back_of(emitter, before) orelse return null;
        const held = emitter.tokens[opener].text(emitter.source);

        const chained = walk.text_is(held, "if") or walk.text_is(held, "while") or
            walk.text_is(held, "&");

        return if (chained) before else null;
    }

    return null;
}

fn chain_anded(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    if (!walk.text_is(emitter.tokens[position].text(emitter.source), "&")) return false;

    const next = emit.ahead_of(emitter, position) orelse return false;
    if (!walk.text_is(emitter.tokens[next].text(emitter.source), "&")) return false;
    return emitter.tokens[position].end() == emitter.tokens[next].offset;
}

pub fn operand_snuggled(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < emitter.count);

    const orphan = operand_orphan(emitter, position, previous) orelse return false;
    return !orphan;
}

fn operand_stops(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const token = emitter.tokens[position];
    if (walk.is_open(token.kind)) return true;
    if (token.kind == .comment) return true;
    if (join.angle_generic(emitter, position)) return true;

    const text = token.text(emitter.source);
    if (words_contain(operand_stop_marks, text)) return true;
    return words_contain(operand_stop_words, text);
}

pub fn operand_wrap(emitter: *const Emitter, position: u32) ?struct { u32, core.Wrap } {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (!emitter.policy.binary_lines) return null;
    if (emitter.depth == 0) return null;
    if (emitter.tokens[position].kind == .comment) return null;

    const framed = emitter.depth > 1 and
        walk.is_open(emitter.tokens[position].kind) and
        line.frame(emitter).open == position;

    const frame = if (framed) emitter.nest[emitter.depth - 2] else line.frame(emitter);
    const seated = emitter.depth - @intFromBool(framed);
    if (operand_wrapped(emitter, seated)) return null;
    if (!split.headed(emitter, frame.open)) return null;

    const head = emit.ahead_of(emitter, frame.open) orelse return null;
    if (head > position) return null;
    if (comment.header_clauses(emitter, frame.open)) return null;

    const stop = emit.back_of(emitter, frame.close) orelse return null;
    return operand_wrap_ranked(emitter, position, head, stop);
}

fn operand_wrap_ranked(
    emitter: *const Emitter,
    position: u32,
    head: u32,
    stop: u32,
) ?struct { u32, core.Wrap } {
    assert(head <= position);
    assert(stop < emitter.count);

    var ranks: [binary_operator_max]struct { u32, u32 } = @splat(.{ 0, 0 });
    const count = operand_ranked(emitter, head, stop, &ranks) orelse return null;
    var floor: u32 = std.math.maxInt(u32);
    var rank_index: u32 = 0;

    while (rank_index < count) : (rank_index += 1) {
        if (ranks[rank_index][1] < floor) floor = ranks[rank_index][1];
    }

    const coded_opens = operand_coded(emitter, position, &ranks, count, floor);
    const opens = position == head or coded_opens;
    if (!opens) return null;

    var end = stop;
    var end_index: u32 = 0;

    while (end_index < count) : (end_index += 1) {
        const at = ranks[end_index][0];
        const rank = ranks[end_index][1];
        const matches = at > position and rank == floor;

        if (matches) {
            end = at -| 1;

            break;
        }
    }

    var from = position;
    if (position != head) from = emit.ahead_of(emitter, position) orelse return null;
    if (end <= from) return null;

    const owing = owing: {
        const after = emit.ahead_of(emitter, end) orelse break :owing 0;
        if (!wrapping_operator(emitter, after)) break :owing 0;

        break :owing 1 + emitter.tokens[after].length;
    };

    return operand_wrap_room(emitter, from, end, floor, owing);
}

fn operand_wrap_room(
    emitter: *const Emitter,
    from: u32,
    end: u32,
    floor: u32,
    owing: u32,
) ?struct { u32, core.Wrap } {
    assert(from < end);
    assert(end < emitter.count);
    assert(owing < std.math.maxInt(u32));

    var inside: [binary_operator_max]struct { u32, u32 } = @splat(.{ 0, 0 });
    const inner = operand_ranked(emitter, from, end, &inside) orelse return null;
    var inner_index: u32 = 0;

    while (inner_index < inner) : (inner_index += 1) {
        if (inside[inner_index][1] <= floor) return null;
    }

    const room = (wrap.header_led(emitter) + 1) * emitter.options.indent_width +
        printed_columns(emitter, from, end) + owing;

    if (room > emitter.options.line_width) return .{ end, .argued };
    return null;
}

fn operand_coded(
    emitter: *const Emitter,
    position: u32,
    ranks: *const [binary_operator_max]struct { u32, u32 },
    count: u32,
    floor: u32,
) bool {
    assert(position < emitter.count);
    assert(count <= binary_operator_max);

    const held = split.coded_at(emitter, position) orelse return false;
    var index: u32 = 0;

    while (index < count) : (index += 1) {
        const matched = ranks[index][0] == held and ranks[index][1] == floor;
        if (matched) return true;
    }

    return false;
}

fn operand_wrapped(emitter: *const Emitter, seated: u32) bool {
    assert(seated <= brace.nest_depth_max);
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    var index: u32 = 0;

    while (index < emitter.wraps_owed) : (index += 1) {
        if (emitter.wrapped[index].depth >= seated) return true;
    }

    return false;
}

pub fn operand_ranked(
    emitter: *const Emitter,
    head: u32,
    stop: u32,
    ranks: *[binary_operator_max]struct { u32, u32 },
) ?u32 {
    assert(head <= stop);
    assert(stop < emitter.count);

    var count: u32 = 0;
    var depth: u32 = 0;
    var scan = head;

    while (scan <= stop) : (scan += 1) {
        const kind = emitter.tokens[scan].kind;

        const opens = walk.is_open(kind) or kind == .block_start or
            bind.spans_open(emitter, scan);

        const closes = walk.is_close(kind) or kind == .block_end;

        if (opens) {
            depth += 1;
        } else if (closes) {
            depth -|= 1;
        } else if (depth == 0) {
            const scored = emitter.brackets.angles_at(scan) == 0 and
                wrapping_operator(emitter, scan);

            const rank = if (scored)
                call.binary_level(emitter.tokens[scan].text(emitter.source))
            else
                call.binary_level_max;

            if (rank < call.binary_level_max) {
                if (count == binary_operator_max) return null;

                ranks[count] = .{ scan, rank };
                count += 1;
            }
        } else {}
    }

    if (count == 0) return null;
    return count;
}

fn operator_led(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.line_first < emitter.count);

    const leading = operator_led_tier(emitter, emitter.line_first) orelse return false;
    const held = operator_led_tier(emitter, position) orelse return false;
    const before = emit.back_of(emitter, emitter.line_first) orelse return false;
    if (!emit.operand_at(emitter, before)) return false;
    if (emitter.line_first >= position) return false;
    return held >= leading;
}

fn operator_led_tier(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.policy.binding_words.len <= std.math.maxInt(u32));

    const token = emitter.tokens[position];
    const text = if (token.is_punctuation(.ampersand_double)) "&&" else token.text(emitter.source);

    for (emitter.policy.binding_words, 0..) |words, tier| {
        if (words_contain(words, text)) {
            assert(tier < emitter.policy.binding_words.len);

            return @intCast(tier);
        }
    }

    return null;
}

pub fn operator_leads(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.binary_parts) return false;
    if (!wrapping_operator(emitter, position)) return false;
    if (!walk.text_is(emitter.tokens[position].text(emitter.source), "*")) return true;

    var before = emit.back_of(emitter, position);

    for (0..wrapping_comment_max) |_| {
        const held = before orelse return true;
        if (emitter.tokens[held].kind != .comment) break;

        before = emit.back_of(emitter, held);
    }

    const held = before orelse return true;
    return emitter.tokens[held].kind != .block_end;
}

pub fn owned_break(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    if (heritage.broken(emitter, position)) return true;
    if (unite.union_broken(emitter, position)) return true;
    return union_closed(emitter, position);
}

pub fn owned_join(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    if (heritage.joined(emitter, position)) return true;
    return unite.union_joined(emitter, position);
}

fn paren_intersected(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    if (!emit.roled(emitter, open, brace.role_type)) return false;

    if (emit.back_of(emitter, open)) |held| {
        if (line.word_is(emitter, held, ampersand_words)) {
            const found = emit.back_of(emitter, held) orelse return false;
            return emitter.tokens[found].kind == .block_end;
        }
    }

    const held = emit.ahead_of(emitter, close) orelse return false;
    return line.word_is(emitter, held, ampersand_words);
}

fn paren_membered(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.tokens[open].is_punctuation(.paren_open));

    const bar = emit.back_of(emitter, open) orelse return false;
    if (!walk.text_is(emitter.tokens[bar].text(emitter.source), "|")) return false;

    const held = emit.back_of(emitter, bar) orelse return false;
    const token = emitter.tokens[held];
    if (token.ends_a_value()) return true;
    return walk.text_is(token.text(emitter.source), ">");
}

fn paren_returned(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.tokens[open].is_punctuation(.paren_open));

    const colon = emit.back_of(emitter, open) orelse return false;
    if (!emitter.tokens[colon].is_punctuation(.colon)) return false;

    const held = emit.back_of(emitter, colon) orelse return false;
    return emitter.tokens[held].is_punctuation(.paren_close);
}

pub fn printed_columns(emitter: *const Emitter, from: u32, to: u32) u32 {
    if (from <= to) assert(to < emitter.count);

    var previous: ?u32 = null;
    var scan = from;
    var width: u32 = 0;

    while (scan <= to) {
        const token = emitter.tokens[scan];
        const skipped = token.length == 0 or token.kind == .newline;

        if (skipped) {
            scan += 1;

            continue;
        }

        if (tmpl.template_body(emitter, scan)) |close| {
            if (previous) |held| width += @intFromBool(printed_blank(emitter, held, scan));

            width += tmpl.template_columns(emitter, scan, close);
            previous = close;
            scan = close + 1;

            continue;
        }

        if (jsx.element_end(emitter, scan)) |close| {
            if (previous) |held| width += @intFromBool(printed_blank(emitter, held, scan));

            width += walk.columns(emitter.source, token.offset, emitter.tokens[close].end());
            previous = close;
            scan = close + 1;

            continue;
        }

        if (printed_dropped(emitter, scan)) {
            scan += 1;

            continue;
        }

        width += quoted_columns(emitter, scan);

        if (previous) |held| {
            width += @intFromBool(printed_blank(emitter, held, scan));

            if (walk.text_is(emitter.tokens[held].text(emitter.source), "=>")) {
                if (tern.ternary_headed(emitter, scan) != null) width += 2;
            }
        }

        previous = scan;
        scan += 1;
    }

    return width;
}

pub fn printed_blank(emitter: *const Emitter, previous: u32, position: u32) bool {
    assert(previous < position);
    assert(position < emitter.count);

    const held = emitter.tokens[previous];
    const token = emitter.tokens[position];
    const before = held.text(emitter.source);
    const text = token.text(emitter.source);

    if (emit.is_dot(emitter, position)) return false;
    if (emit.is_dot(emitter, previous)) return false;
    if (jsx.holed(emitter, previous)) return false;
    if (jsx.holed(emitter, position)) return false;
    if (held.kind == .block_start) return join.closing_of(emitter, previous) != position;

    if (token.kind == .block_end) {
        const open = emitter.brackets.open_of(position) orelse return false;
        return emitter.tokens[open].kind == .block_start and open != previous;
    }

    if (words_contain(tight_after, before)) return false;
    if (walk.is_open(held.kind)) return false;
    if (tagged(emitter, previous, position)) return false;
    if (words_contain(tight_before, text)) return tight_blank(emitter, previous, position);
    if (walk.is_close(token.kind)) return tight_blank(emitter, previous, position);
    if (walk.text_is(text, ":")) return tern.ternary(emitter, position);
    if (walk.text_is(text, "?")) return !tern.optional(emitter, position);

    const opening = token.is_punctuation(.bracket_open) or token.is_punctuation(.paren_open);
    if (opening) return printed_opening(emitter, previous, position);
    return printed_spaced(emitter, previous, position);
}

fn printed_dropped(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    if (emitter.tokens[position].is_punctuation(.comma)) {
        if (emit.ahead_of(emitter, position)) |held| {
            if (walk.is_close(emitter.tokens[held].kind)) return true;
        }

        if (join.angle_comma_dropped(emitter, position)) return true;
    }

    if (emitter.tokens[position].is_punctuation(.semicolon)) {
        if (emit.ahead_of(emitter, position)) |held| {
            if (typed_brace(emitter, held)) return true;

            if (emitter.tokens[held].kind == .block_end) {
                if (type_closed(emitter, held)) return true;
            }
        }
    }

    const dropped = wrap_dropped(emitter, position);

    assert(!dropped);

    return dropped;
}

fn printed_opening(emitter: *const Emitter, previous: u32, position: u32) bool {
    assert(previous < position);
    assert(position < emitter.count);

    const held = emitter.tokens[previous];
    const token = emitter.tokens[position];
    const before = held.text(emitter.source);
    const braced = held.kind == .block_end and token.is_punctuation(.bracket_open);
    const opened = walk.text_is(before, "<") and !comparing(emitter, previous);
    const angled = opened or printed_closing(emitter, previous, position);

    if (held.is_punctuation(.paren_close)) {
        if (emitter.brackets.open_of(previous)) |open| {
            if (split.headed(emitter, open)) return true;
        }
    }

    if (emit.operand_at(emitter, previous)) return false;
    if (braced) return false;
    return !angled;
}

fn printed_closing(emitter: *const Emitter, previous: u32, position: u32) bool {
    assert(previous < position);
    assert(position < emitter.count);

    if (!closes_angles(emitter.tokens[previous].text(emitter.source))) return false;
    if (emitter.brackets.angles_at(previous) == 0) return false;
    if (emitter.tokens[position].is_punctuation(.bracket_open)) return true;
    if (printed_constructed(emitter, previous)) return true;
    return link.angle_membered(emitter, previous);
}

fn printed_constructed(emitter: *const Emitter, close: u32) bool {
    assert(close < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const open = join.angle_head(emitter, close) orelse return false;
    const name = emit.back_of(emitter, open) orelse return false;
    const held = emit.back_of(emitter, name) orelse return false;

    return walk.text_is(emitter.tokens[held].text(emitter.source), "new");
}

fn printed_spaced(emitter: *const Emitter, previous: u32, position: u32) bool {
    assert(previous < position);
    assert(position < emitter.count);

    const held = emitter.tokens[previous];
    const token = emitter.tokens[position];
    const before = held.text(emitter.source);
    const text = token.text(emitter.source);
    const angled = emitter.brackets.angles_at(position) > 0;

    if (walk.text_is(before, "<")) {
        if (!comparing(emitter, previous)) return false;
    }

    if (walk.text_is(text, ">")) {
        if (angled) return false;
    }

    if (walk.text_is(text, "<")) {
        if (emitter.brackets.angles_at(position + 1) > 0) {
            if (!comparing(emitter, position)) {
                if (held.ends_a_value()) return false;
            }
        }
    }

    const tight = line.word_is(emitter, position, emitter.policy.tight_from_source) or
        line.word_is(emitter, previous, emitter.policy.tight_from_source);

    if (tight) {
        if (held.end() == token.offset) {
            const spaced = emit.roled(emitter, position, brace.role_spaced) or
                emit.roled(emitter, previous, brace.role_spaced);

            if (!spaced) return false;
        }
    }

    return true;
}

fn quoted_columns(emitter: *const Emitter, position: u32) u32 {
    assert(position < emitter.count);

    const token = emitter.tokens[position];
    const plain = walk.columns(emitter.source, token.offset, token.end());

    if (key.unquoting(emitter, position)) |found| {
        const returned = walk.columns(emitter.source, found.offset, found.offset + found.length);

        assert(returned < std.math.maxInt(u32));

        return returned;
    }

    const quoted, const quote = emit.requoting(emitter, position) orelse return plain;
    const former: u8 = if (quote == '"') '\'' else '"';
    var held: usize = 0;
    var written: usize = 0;

    while (held < quoted.len) {
        if (quoted[held] != '\\') {
            written += @as(usize, @intFromBool(quoted[held] == quote)) + 1;
            held += 1;

            continue;
        }

        if (held + 1 >= quoted.len) {
            written += 1;

            break;
        }

        written += @as(usize, @intFromBool(quoted[held + 1] != former)) + 1;
        held += 2;
    }

    assert(held >= quoted.len);

    const grown = std.math.cast(i64, written) orelse 0;
    const shrunk = std.math.cast(i64, quoted.len) orelse 0;
    const moved = std.math.cast(i32, grown - shrunk) orelse 0;

    if (moved >= 0) {
        const returned = plain +| @as(u32, @intCast(moved));

        assert(returned < std.math.maxInt(u32));

        return returned;
    }

    const returned = plain -| @abs(moved);

    assert(returned < std.math.maxInt(u32));

    return returned;
}

pub fn comment_operand(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < emitter.count);

    if (!emitter.policy.chain_simples) return false;

    const token = emitter.tokens[previous];
    if (token.kind != .comment) return false;
    if (!std.mem.startsWith(u8, token.text(emitter.source), "//")) return false;

    const text = emitter.tokens[position].text(emitter.source);

    if (!words_contain(wrapped_operators, text)) {
        if (!words_contain(emitter.policy.wrap_words, text)) return false;
    }

    const held = join.coded_before(emitter, previous) orelse return false;
    if (body.parts_at(emitter, held, previous)) return false;
    return emitter.tokens[held].ends_a_value();
}

fn requotes(emitter: *const Emitter, held: u32, position: u32, scopes: *const Scopes) bool {
    assert(position <= held);
    assert(held < emitter.count);

    if (scopes.templated()) return false;
    if (scopes.valued()) return true;

    var scan = held;

    while (scan > position) {
        scan -= 1;

        const token = emitter.tokens[scan];
        const skipped = token.kind == .newline or token.length == 0;
        if (skipped) continue;
        return token.kind.eql(.{ .punctuation = .assign });
    }

    return false;
}

pub fn respanned(emitter: *Emitter, position: u32, close: u32, indents: bool) error{Overflow}!void {
    assert(position <= close);
    assert(close < emitter.count);

    const from = emitter.tokens[position].offset;
    const to = emitter.tokens[close].end();

    const tabbed = indents and !emitter.options.tabs and
        std.mem.findScalar(u8, emitter.source[from..to], '\t') != null;

    const quoted = emitter.policy.string_quotes;
    const plain = !tabbed and !quoted;
    if (plain) return emit.spanned(emitter, position, close);

    const offset = emitter.arena.count();

    rewritten(emitter, from, to, position, close, tabbed) catch |err| {
        emitter.arena.truncate(offset);

        return err;
    };

    if (walk.text_eql(emitter.arena.const_slice()[offset..], emitter.source[from..to])) {
        emitter.arena.truncate(offset);

        return emit.spanned(emitter, position, close);
    }

    emitter.previous = close;
    emitter.resume_at = close + 1;
    emitter.suppress_space = false;

    try emitter.document.push(.{ .verbatim_arena = .{
        .offset = offset,
        .length = emitter.arena.count() - offset,
    } });
}

fn rewritten(
    emitter: *Emitter,
    from: u32,
    to: u32,
    position: u32,
    close: u32,
    tabbed: bool,
) error{Overflow}!void {
    assert(from <= to);
    assert(position <= close);
    assert(close < emitter.count);

    const width = emitter.options.indent_width;
    var at = from;
    var held = position;
    var scopes = Scopes.empty;

    while (at < to) {
        held = rewritten_scoped(emitter, close, at, &scopes, held);

        if (try rewritten_token(emitter, held, position, close, at, &scopes)) {
            at = emitter.tokens[held].end();

            continue;
        }

        const inside = rewritten_inside(emitter, held, close, at, &scopes);

        at = try indented(emitter, emitter.source, at, to, tabbed and !inside, width);
    }
}

fn rewritten_scoped(emitter: *const Emitter, close: u32, at: u32, scopes: *Scopes, held: u32) u32 {
    assert(held <= emitter.count);
    assert(close < emitter.count);

    var scan = held;

    while (scan <= close) {
        if (emitter.tokens[scan].end() > at) break;

        const token = emitter.tokens[scan];
        const quoted = token.kind == .string and walk.text_is(token.text(emitter.source), "`");
        const opens = token.kind == .block_start or walk.substituting(emitter.source, token);

        if (quoted) {
            if (scopes.templated()) {
                scopes.close();
            } else {
                scopes.open(true);
            }
        } else if (opens) {
            scopes.open(false);
        } else if (token.kind == .block_end) {
            scopes.close();
        } else {}

        scan += 1;
    }

    return scan;
}

fn rewritten_token(
    emitter: *Emitter,
    held: u32,
    position: u32,
    close: u32,
    at: u32,
    scopes: *const Scopes,
) error{Overflow}!bool {
    assert(position <= held);
    assert(close < emitter.count);

    if (held > close) return false;
    if (emitter.tokens[held].offset != at) return false;

    if (emit.requoting(emitter, held)) |wanted| {
        if (requotes(emitter, held, position, scopes)) {
            const spelling, const quote = wanted;

            try emitter.arena.push_byte(quote);
            try requoted(emitter.arena, spelling, quote);
            try emitter.arena.push_byte(quote);

            return true;
        }
    }

    if (scopes.valued()) {
        if (list.arrowed(emitter, held)) {
            const spelled = emitter.tokens[held].text(emitter.source);

            try emitter.arena.push("(");
            try emitter.arena.push(spelled);
            try emitter.arena.push(")");

            return true;
        }
    }

    return false;
}

fn rewritten_inside(
    emitter: *const Emitter,
    held: u32,
    close: u32,
    at: u32,
    scopes: *const Scopes,
) bool {
    assert(close < emitter.count);
    assert(scopes.depth <= brace.nest_depth_max);

    if (held > close) return false;

    const token = emitter.tokens[held];
    if (token.offset >= at) return false;

    const quotable = token.kind == .comment or token.kind == .string;
    if (!quotable) return false;
    if (scopes.depth > 0) return true;

    const spelled = token.text(emitter.source);
    const quoted = std.mem.startsWith(u8, spelled, "\"") or std.mem.startsWith(u8, spelled, "'");

    return quoted;
}

fn shift_width(emitter: *const Emitter, position: u32) u32 {
    assert(position < emitter.count);

    if (!walk.text_is(emitter.tokens[position].text(emitter.source), ">")) return 0;
    if (emitter.brackets.angles_at(position) > 0) return 0;
    if (shifted_pair(emitter, position -% 1, position)) return 0;

    var found: u32 = 1;
    var scan = position;

    while (found < shift_width_max) {
        const ahead = emit.ahead_of(emitter, scan) orelse break;
        const held = emitter.tokens[ahead];
        if (!walk.text_is(held.text(emitter.source), ">")) break;
        if (emitter.tokens[scan].end() != held.offset) break;

        found += 1;
        scan = ahead;
    }

    assert(found <= shift_width_max);

    return found;
}

pub fn shift_tailed(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const ahead = emit.ahead_of(emitter, position) orelse return false;

    assert(ahead > position);

    return shifted_pair(emitter, position, ahead);
}

pub fn shifted_pair(emitter: *const Emitter, previous: u32, position: u32) bool {
    assert(position < emitter.count);

    if (previous >= emitter.count) return false;
    if (previous >= position) return false;
    if (!walk.text_is(emitter.tokens[previous].text(emitter.source), ">")) return false;
    if (!walk.text_is(emitter.tokens[position].text(emitter.source), ">")) return false;

    assert(previous < position);

    return emitter.tokens[previous].end() == emitter.tokens[position].offset;
}

pub fn spread_arrows(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.hug_lasts) return false;
    if (!emitter.tokens[open].is_punctuation(.paren_open)) return false;
    if (spread_arrows_typed(emitter, open)) return false;
    if (!arrow_opens(emitter, open)) return false;

    const close = join.closing_of(emitter, open) orelse return false;
    const items = spread_items(emitter, open, close);

    if (!call.spread_arrowed(emitter, close)) return false;
    if (items > 1) return true;
    if (!emitter.policy.hug_soles) return false;
    if (items != 1) return false;
    if (!spread_arrows_sole(emitter, open, close)) return false;
    return !spread_hugs(emitter, open, close);
}

fn spread_arrows_typed(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.tokens[open].is_punctuation(.paren_open));

    const held = emit.back_of(emitter, open) orelse return false;
    if (!emitter.tokens[held].is_punctuation(.colon)) return false;

    const before = emit.back_of(emitter, held) orelse return false;
    return emitter.tokens[before].is_punctuation(.paren_close);
}

fn spread_arrows_sole(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    if (spread_typing(emitter, open, close)) return true;
    if (call.arrow_returns(emitter, close)) return true;
    if (unite.arrow_valued(emitter, open)) return true;
    return unite.arrow_param_argued(emitter, open);
}

fn arrow_opens(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const held = emit.back_of(emitter, open) orelse return true;
    const token = emitter.tokens[held];

    assert(held < open);

    if (token.kind == .identifier) return false;
    if (token.kind != .keyword) return true;
    return words_contain(arrow_heads, token.text(emitter.source));
}

fn spread_typing(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    const head = spread_within(emitter, open, close) orelse return false;
    const held = emit.ahead_of(emitter, head) orelse return false;

    return held < close;
}

fn spread_hugs(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    const head = spread_within(emitter, open, close) orelse return false;
    const kind = emitter.tokens[head].kind;
    if (kind == .block_start) return true;
    if (kind.eql(.{ .punctuation = .bracket_open })) return true;
    if (kind != .identifier) return false;

    var scan = emit.ahead_of(emitter, head) orelse return false;

    if (walk.text_is(emitter.tokens[scan].text(emitter.source), "?")) {
        if (emit.ahead_of(emitter, scan)) |held| scan = held;
    }

    if (!emitter.tokens[scan].is_punctuation(.colon)) return false;

    const typed = emit.ahead_of(emitter, scan) orelse return false;
    if (emitter.tokens[typed].kind != .block_start) return false;

    const end = join.closing_of(emitter, typed) orelse return false;
    const after = emit.ahead_of(emitter, end) orelse return false;

    return after == close;
}

pub fn wrapped_paren(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.return_parens) return false;
    if (!emitter.tokens[open].is_punctuation(.paren_open)) return false;

    const held = emit.back_of(emitter, open) orelse return false;
    return words_contain(wrapped_words, emitter.tokens[held].text(emitter.source));
}

fn spread_break(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    const next = emit.ahead_of(emitter, position) orelse return false;
    return body.parted_by(emitter, emitter.tokens[position].end(), emitter.tokens[next].offset) > 0;
}

pub fn spread_breaks(emitter: *const Emitter, from: u32, to: u32) bool {
    assert(from <= to);
    assert(to <= emitter.count);

    var scan = from;

    while (scan < to) {
        const end = tmpl.template_body(emitter, scan) orelse jsx_body(emitter, scan);

        if (end) |held| {
            scan = held + 1;

            continue;
        }

        if (body.parts(emitter, scan)) return true;

        scan += 1;
    }

    return false;
}

fn spread_edge(emitter: *const Emitter, position: u32, depth: u32, open: u32) bool {
    assert(position < emitter.count);
    assert(open <= position);

    if (position == open) return true;
    if (depth != 0) return false;

    const token = emitter.tokens[position];
    const edged = token.is_punctuation(.comma) or token.is_punctuation(.semicolon);
    if (!edged) return false;
    return emitter.brackets.angles_at(position) == 0;
}

pub fn spread_forced(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    if (!emitter.policy.hug_lasts) return false;
    if (!sole.listed(emitter, close)) return false;
    if (list.headed_loop(emitter, open)) return false;

    if (emitter.tokens[open].is_punctuation(.bracket_open)) {
        var heads: [argument_head_max]u32 = @splat(0);
        const found = spread_heads(emitter, open, close, &heads);
        if (found <= 1) return false;
        return spread_breaks(emitter, open + 1, close);
    }

    if (!emitter.tokens[open].is_punctuation(.paren_open)) return false;

    var heads: [argument_head_max]u32 = @splat(0);
    const count = spread_heads(emitter, open, close, &heads);
    if (count == 0) return false;
    if (spread_hooked(emitter, &heads, count, close)) return false;

    const last = heads[count - 1];
    const from, const to = spread_forced_span(emitter, &heads, count, last, open, close);

    return spread_breaks(emitter, from, to);
}

fn spread_forced_span(
    emitter: *const Emitter,
    heads: *const [argument_head_max]u32,
    count: u32,
    last: u32,
    open: u32,
    close: u32,
) struct { u32, u32 } {
    assert(count > 0);
    assert(open < close);
    assert(last < emitter.count);
    assert(heads[count - 1] == last);

    if (spread_hugged(emitter, last, close)) return .{ open + 1, last };

    if (count == 2) {
        if (spread_hugged(emitter, heads[0], close)) return .{ heads[1], close };
    }

    return .{ open + 1, close };
}

fn spread_headline(emitter: *const Emitter, head: u32, close: u32) u32 {
    assert(head < close);
    assert(close < emitter.count);

    if (emitter.tokens[head].is_punctuation(.bracket_open)) return head;
    if (walk.text_is(emitter.tokens[head].text(emitter.source), "<")) return head;

    var depth: u32 = 0;
    var scan = head;

    while (scan < close) {
        const kind = emitter.tokens[scan].kind;

        if (kind == .block_start) {
            if (depth == 0) return scan;
        }

        if (depth == 0) {
            if (headline_arrow(emitter, scan, close)) |held| return held;
        }

        if (walk.is_open(kind)) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            depth -|= 1;
        } else {}

        scan += 1;
    }

    return close;
}

pub fn spread_heads(
    emitter: *const Emitter,
    open: u32,
    close: u32,
    heads: *[argument_head_max]u32,
) u32 {
    assert(open < close);
    assert(close < emitter.count);

    var found: u32 = 0;
    var depth: u32 = 0;
    var scan = open;

    while (scan < close) {
        const end = tmpl.template_body(emitter, scan) orelse jsx_body(emitter, scan);

        if (end) |held| {
            scan = held + 1;

            continue;
        }

        const kind = emitter.tokens[scan].kind;

        const comma = depth == 0 and emitter.tokens[scan].is_punctuation(.comma) and
            emitter.brackets.angles_at(scan) == 0;

        const nested = scan > open and walk.is_open(kind);
        const heads_one = scan == open or comma;

        if (heads_one) {
            const held = emit.ahead_of(emitter, scan) orelse break;
            if (held >= close) break;
            if (found == argument_head_max) return 0;

            heads[found] = held;
            found += 1;
        } else if (nested) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            depth -|= 1;
        } else {}

        scan += 1;
    }

    assert(found <= argument_head_max);

    return found;
}

fn spread_hooked(
    emitter: *const Emitter,
    heads: *const [argument_head_max]u32,
    count: u32,
    close: u32,
) bool {
    assert(close < emitter.count);
    assert(count <= argument_head_max);

    const ranged = count == 2 or count == 3;
    if (!ranged) return false;

    const at = count - 2;
    const held = heads[at];

    if (!emitter.tokens[heads[count - 1]].is_punctuation(.bracket_open)) return false;
    if (!emitter.tokens[held].is_punctuation(.paren_open)) return false;

    const after = emit.ahead_of(emitter, held) orelse return false;
    if (!emitter.tokens[after].is_punctuation(.paren_close)) return false;
    return spread_hugged(emitter, held, close);
}

pub fn spread_hugging(emitter: *const Emitter, open: u32, close: u32) ?u32 {
    assert(open < emitter.count);
    assert(close < emitter.count);

    if (!emitter.tokens[open].is_punctuation(.paren_open)) return null;
    if (close <= open) return null;

    var heads: [argument_head_max]u32 = @splat(0);
    const found = spread_heads(emitter, open, close, &heads);
    if (found == 0) return null;

    if (found == 2) {
        if (call.hugged_first(emitter, open, close, heads[0] + 1)) return heads[0];
    }

    const tail = heads[found - 1];
    if (!spread_hugged(emitter, tail, close)) return null;

    if (found > 1) {
        if (hug_concise(emitter, heads[found - 2], tail, close)) return null;
    }

    return hug_fitted(emitter, open, close, tail);
}

pub fn spread_hugged(emitter: *const Emitter, head: u32, close: u32) bool {
    assert(head < close);
    assert(close < emitter.count);

    const token = emitter.tokens[head];
    const braced = token.kind == .block_start or token.is_punctuation(.bracket_open);
    if (braced) return join.closing_of(emitter, head) != emit.ahead_of(emitter, head);
    if (words_contain(hugged_heads, token.text(emitter.source))) return true;

    if (token.is_punctuation(.paren_open)) {
        const held = join.closing_of(emitter, head) orelse return false;
        if (held >= close) return false;
        return call.spread_arrowed(emitter, held);
    }

    if (token.kind != .identifier) return false;
    if (call.spread_arrowed(emitter, head)) return true;
    return spread_typed(emitter, head);
}

pub fn spread_listed(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < emitter.count);

    if (!emitter.policy.list_spreads) return false;
    if (emitter.depth == 0) return false;
    if (list.assign_owed(emitter)) return false;

    const frame = line.frame(emitter);
    if (!frame.parted) return false;
    if (bind.sequence_spread(emitter, frame.open)) return false;

    const commented = emitter.tokens[position].kind == .comment and
        !spread_break(emitter, previous);

    if (commented) return false;
    if (previous == frame.open) return true;
    if (position == frame.close) return true;
    return spread_edge(emitter, previous, 0, frame.open);
}

pub fn spread_source(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < emitter.count);
    assert(close < emitter.count);

    if (!emitter.policy.list_spreads) return false;
    if (close <= open) return false;
    if (body.bodied_brace(emitter, open)) return false;

    if (emitter.policy.chain_simples) {
        if (grouping_paren(emitter, open, close)) return false;
    }

    if (unite.union_parenthesized(emitter, open)) return false;
    if (join.paren_literal(emitter, open, close)) return false;

    var depth: u32 = 0;
    var scan = open;

    while (scan < close) {
        const end = tmpl.template_body(emitter, scan) orelse jsx_body(emitter, scan);

        if (end) |held| {
            scan = held + 1;

            continue;
        }

        const kind = emitter.tokens[scan].kind;
        const nested = scan > open and walk.is_open(kind);

        if (nested) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            depth -|= 1;
        } else {}

        const trailing = if (emit.ahead_of(emitter, scan)) |held| held == close else false;
        const edged = !trailing and spread_edge(emitter, scan, depth, open);
        const breaks = edged and spread_break(emitter, scan);
        if (breaks) return true;

        scan += 1;
    }

    return false;
}

fn spread_typed(emitter: *const Emitter, head: u32) bool {
    assert(head < emitter.count);
    assert(emitter.tokens[head].kind == .identifier);

    const after = emit.ahead_of(emitter, head) orelse return false;
    if (!emitter.tokens[after].is_punctuation(.colon)) return false;

    const held = emit.ahead_of(emitter, after) orelse return false;
    return emitter.tokens[held].kind == .block_start;
}

pub fn statement_wrap(emitter: *const Emitter, position: u32) ?struct { u32, core.Wrap } {
    assert(position < emitter.count);

    if (!emitter.policy.binary_lines) return null;
    if (statement_wrapped(emitter, position)) return null;

    const unary = emitter.policy.chain_simples and
        line.word_is(emitter, position, statement_unaries);

    const operand = line.word_is(emitter, position, emitter.policy.operand_words) or unary;
    const kind = emitter.tokens[position].kind;
    if (kind == .comment) return null;

    if (kind == .keyword) {
        if (!operand) return null;
    }

    if (emitter.depth > 0) {
        if (edge.member_bodied(emitter, run_frame(emitter, position).open)) return null;
    }

    const sequenced = statement_runs(emitter, position) orelse return null;

    const end = statement_stop(emitter, position) orelse blk: {
        if (!sequenced) return null;

        break :blk run_frame(emitter, position).close;
    };

    const stop = emit.back_of(emitter, end) orelse return null;
    if (stop <= position) return null;
    if (wrap.statement_assigns(emitter, position, stop)) return null;

    var ranks: [binary_operator_max]struct { u32, u32 } = @splat(.{ 0, 0 });
    const ranked = operand_ranked(emitter, position, stop, &ranks) orelse return null;

    assert(ranked <= binary_operator_max);

    if (ranked == 0) return null;
    if (spread_breaks(emitter, position, end)) return .{ stop, .argued };
    if (wrap.statement_expanded(emitter, position, stop)) return .{ stop, .argued };
    if (statement_wide(emitter, position, end)) return .{ stop, .argued };
    return null;
}

fn tagged(emitter: *const Emitter, previous: u32, position: u32) bool {
    assert(previous < position);
    assert(position < emitter.count);

    if (!walk.text_is(emitter.tokens[position].text(emitter.source), "`")) return false;
    if (!walk.ends_operand(emitter.tokens[previous].kind)) return false;
    return tmpl.template_body(emitter, position) != null;
}

fn tight_blank(emitter: *const Emitter, previous: u32, position: u32) bool {
    assert(previous < position);
    assert(position < emitter.count);

    const held = emitter.tokens[previous];
    const text = emitter.tokens[position].text(emitter.source);
    const unary = walk.text_is(text, "!") and !held.ends_a_value();
    if (unary) return true;
    return comment.header_semi_gap(emitter, previous, position);
}

pub fn type_closed(emitter: *const Emitter, close: u32) bool {
    assert(close < emitter.count);

    const open = emitter.brackets.open_of(close) orelse return false;

    assert(open < close);

    return type_framed(emitter, open);
}

pub fn type_framed(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    if (emitter.tokens[open].kind != .block_start) return false;
    return emit.roled(emitter, open, brace.role_type);
}

pub fn typed_brace(emitter: *const Emitter, close: u32) bool {
    assert(close < emitter.count);

    if (emitter.policy.type_words.len == 0) return false;
    if (emitter.tokens[close].kind != .block_end) return false;

    const open = emitter.brackets.open_of(close) orelse return false;

    assert(open < close);

    return typed_open(emitter, open);
}

pub fn typed_open(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (emitter.policy.type_words.len == 0) return false;
    if (emitter.tokens[open].kind != .block_start) return false;
    if (body.bodied_brace(emitter, open)) return false;

    if (emit.back_of(emitter, open)) |held| {
        if (line.group_word(emitter, held)) return true;
    }

    return typed_members(emitter, open);
}

pub fn union_bodied(emitter: *const Emitter, curly: u32) ?u32 {
    assert(curly < emitter.count);
    assert(emitter.line_first < emitter.count);

    if (!emitter.policy.union_parts) return null;
    if (emitter.tokens[curly].kind != .block_start) return null;

    const barred = walk.text_is(emitter.tokens[emitter.line_first].text(emitter.source), "|");

    if (!barred) {
        if (!union_object_closed(emitter, emitter.line_first)) return null;
    }

    const before = emit.back_of(emitter, curly) orelse return null;
    if (walk.text_is(emitter.tokens[before].text(emitter.source), "|")) return null;

    const opened = union_open(emitter, curly) orelse return null;
    var open = opened;

    if (predicate_returned(emitter, opened)) {
        open = predicate_colon_of(emitter, opened) orelse return null;
    }

    if (!emitter.tokens[open].kind.eql(.{ .punctuation = .colon })) return null;

    const walked = list.signature_walked(emitter, curly) orelse return null;
    const ahead = emit.back_of(emitter, open) orelse return null;
    if (ahead != walked[1]) return null;

    const paren = unite.union_return_paren(emitter, open);
    const opens = line_opened(emitter, paren orelse open) orelse return null;
    if (opens >= emitter.line_first) return null;
    return line.level_at(emitter, opens);
}

fn union_object_closed(emitter: *const Emitter, close: u32) bool {
    assert(close < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (emitter.tokens[close].kind != .block_end) return false;

    const open = emitter.brackets.open_of(close) orelse return false;
    const held = emit.back_of(emitter, open) orelse return false;

    return walk.text_is(emitter.tokens[held].text(emitter.source), "|");
}

fn union_closed(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    if (!emitter.tokens[position].is_punctuation(.paren_close)) return false;

    const open = emitter.brackets.open_of(position) orelse return false;
    if (!union_paren(emitter, open)) return false;

    const head = line.coding(emitter, open) orelse return false;
    const held = union_of(emitter, head) orelse return false;

    assert(held.open < emitter.count);
    assert(head < emitter.count);

    if (held.open != open) return false;
    return union_wide(emitter, &held);
}

pub fn union_frame(emitter: *const Emitter, open: u32) Frame {
    assert(open < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    var depth = emitter.depth;

    while (depth > 0) : (depth -= 1) {
        const held = emitter.nest[depth - 1];
        if (held.open < open) return held;
    }

    return Frame.empty;
}

pub fn union_framed(emitter: *const Emitter) bool {
    assert(emitter.depth <= brace.nest_depth_max);
    assert(emitter.count == emitter.tokens.len);

    if (emitter.depth == 0) return false;

    const frame = line.frame(emitter);
    if (union_itemed(frame.kind)) return true;
    return union_membered(emitter, &frame);
}

fn union_itemed(kind: Token.Kind) bool {
    if (kind == .comment) return false;

    const result = switch (kind) {
        .punctuation => |punctuation| punctuation == .paren_open or punctuation == .bracket_open,
        .block_end, .block_start, .comment, .identifier, .keyword, .newline, .number => false,
        .string => false,
    };

    if (result) assert(walk.is_open(kind));
    if (result) assert(kind != .block_start);

    return result;
}

pub fn union_membered(emitter: *const Emitter, frame: *const Frame) bool {
    assert(frame.open < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (frame.kind != .block_start) return false;
    if (frame.spread == null) return false;
    if (!body.bodied_brace(emitter, frame.open)) return true;
    return type_framed(emitter, frame.open);
}

pub inline fn union_of(emitter: *const Emitter, position: u32) ?Union {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.union_parts) return null;
    if (unite.union_group_holds(emitter, position)) return null;

    const open = union_open(emitter, position) orelse return null;
    return union_of_open(emitter, open);
}

fn union_of_open(emitter: *const Emitter, open: u32) ?Union {
    assert(open < emitter.count);
    assert(emitter.policy.union_parts);

    const casted = line.group_word(emitter, open);

    if (casted) {
        if (unite.cast_group_tail(emitter, open)) {
            if (unite.cast_plain(emitter, open)) return null;
        }
    }

    const membered = union_of_membered(emitter, open);
    const angled = unite.union_listed(emitter, open);
    if (union_of_owed(emitter, casted, membered, angled)) return null;

    if (angled) {
        if (!casted) {
            if (emitter.assigns > 0) return null;
        }
    }

    if (membered) {
        if (unite.union_arrowed(emitter, open)) return null;
    }

    if (!union_typed(emitter, open)) return null;
    if (!union_seated(emitter, open)) return null;
    if (union_inline(emitter, open)) return null;
    if (tern.return_colon(emitter, union_anchor(emitter, open))) return null;
    return union_of_bars(emitter, open);
}

fn union_of_membered(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.depth > 0) {
        const top = line.frame(emitter);
        if (union_membered(emitter, &top)) return true;
    }

    return unite.union_tupled(emitter, open);
}

fn union_of_owed(emitter: *const Emitter, casted: bool, membered: bool, angled: bool) bool {
    assert(emitter.depth <= brace.nest_depth_max);
    assert(emitter.count == emitter.tokens.len);

    if (casted) return false;
    if (membered) return false;
    if (angled) return false;
    if (!list.assign_owed(emitter)) return false;
    return !owed_bodied(emitter);
}

fn union_of_bars(emitter: *const Emitter, open: u32) ?Union {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const coded = line.coding(emitter, open) orelse return null;
    const leading = walk.text_is(emitter.tokens[coded].text(emitter.source), "|");
    var head = coded;
    if (leading) head = line.coding(emitter, coded) orelse return null;
    if (unite.union_paren_grouping(emitter, head) != null) return null;

    const annotated = union_of_annotated(emitter, open);

    const bars, const braced, const count, const stop =
        union_bars(emitter, head, annotated) orelse return null;

    if (unite.union_casted(emitter, head, bars[0])) return null;
    if (union_hugs(emitter, head, &bars, count, stop)) return null;

    if (braced) {
        if (!unite.union_fits(emitter, open, head, &bars, count, stop)) return null;
    }

    return .{
        .bars = bars,
        .count = count,
        .head = head,
        .lead = if (leading) coded else null,
        .open = open,
        .stop = stop,
    };
}

fn union_of_annotated(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (emit.back_of(emitter, open)) |held| {
        if (emitter.tokens[held].kind.eql(.{ .punctuation = .paren_close })) return true;
    }

    return predicate_returned(emitter, open);
}

fn owed_bodied(emitter: *const Emitter) bool {
    assert(emitter.depth <= brace.nest_depth_max);
    assert(emitter.count == emitter.tokens.len);

    if (emitter.assigns > 0) return false;
    if (emitter.owed == 0) return false;

    const depth = emitter.dedents[emitter.owed - 1].depth;
    if (depth >= emitter.depth) return false;

    for (emitter.nest[depth..emitter.depth]) |frame| {
        if (frame.kind == .block_start) {
            if (frame.bodied) return true;
        }
    }

    return false;
}

fn union_inline(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    const head = line_opened(emitter, open) orelse open;
    var depth = emitter.depth;

    while (depth > 0) : (depth -= 1) {
        const frame = emitter.nest[depth - 1];

        if (frame.kind == .block_start) {
            if (frame.open < open) {
                if (union_membered(emitter, &frame)) return false;
                return frame.open >= head;
            }
        }
    }

    return false;
}

const SeatedStep = enum { broke, passed, refused };

fn union_seated(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    var depth = emitter.depth;

    while (depth > 0) {
        depth -= 1;

        const frame = emitter.nest[depth];
        if (frame.open >= open) continue;
        if (union_membered(emitter, &frame)) break;

        switch (union_seated_frame(emitter, &frame, open)) {
            .broke => break,
            .passed => {},
            .refused => return false,
        }
    }

    return true;
}

fn union_seated_frame(emitter: *const Emitter, frame: *const Frame, open: u32) SeatedStep {
    assert(frame.open < open);
    assert(open < emitter.count);

    const angles = emitter.brackets.angles_at(frame.open);
    const block = frame.kind == .block_start;

    if (block) {
        if (frame.spread == null) {
            if (angles == 0) return .broke;
        }
    }

    if (union_itemed(frame.kind)) {
        if (frame.spread != null) {
            if (angles == 0) return .passed;
            if (frame.kind.eql(.{ .punctuation = .bracket_open })) return .passed;
        }
    }

    if (frame.kind.eql(.{ .punctuation = .paren_open })) {
        if (union_seated_returns(emitter, frame.open, open)) return .passed;
    }

    if (!block) return .refused;
    if (frame.spread != null) return .refused;
    if (angles > 0) return .refused;
    return .passed;
}

fn union_seated_returns(emitter: *const Emitter, paren: u32, open: u32) bool {
    assert(paren < open);
    assert(open < emitter.count);

    const close = join.closing_of(emitter, paren) orelse return false;
    const after = emit.ahead_of(emitter, close) orelse return false;

    return after == open;
}

pub fn union_paren(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);

    if (!emitter.tokens[open].is_punctuation(.paren_open)) return false;
    if (emitter.brackets.angles_at(open) > 0) return false;
    if (paren_returned(emitter, open)) return false;

    if (paren_membered(emitter, open)) {
        if (emitter.depth > 0) {
            const held = union_frame(emitter, open);
            if (held.kind.eql(.{ .punctuation = .paren_open })) return false;
        }
    }

    const close = join.closing_of(emitter, open) orelse return false;
    if (paren_intersected(emitter, open, close)) return true;

    const held = emit.ahead_of(emitter, close) orelse return false;
    if (!emitter.tokens[held].is_punctuation(.bracket_open)) return false;

    const found = emit.ahead_of(emitter, held) orelse return false;
    return join.closing_of(emitter, held) == found;
}

pub fn union_skipped(emitter: *const Emitter, close: u32) ?u32 {
    assert(close < emitter.count);

    const open = emitter.brackets.open_of(close) orelse return null;

    assert(open < close);

    if (!walk.is_open(emitter.tokens[open].kind)) return null;
    if (emitter.brackets.substituted(open, close)) return null;
    return open;
}

pub fn wrap_dropped(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.binary_lines) return false;

    const open = wrap_dropped_open(emitter, position) orelse return false;
    const word = emit.back_of(emitter, open) orelse return false;
    const pair = wrap_parens(emitter, word) orelse return false;
    const close = join.closing_of(emitter, open) orelse 0;

    assert(word < open);

    return pair[0] == open and pair[1] == close;
}

fn wrap_dropped_open(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const token = emitter.tokens[position];
    if (token.is_punctuation(.paren_open)) return position;
    if (token.is_punctuation(.paren_close)) return emitter.brackets.open_of(position);
    return null;
}

fn wrap_parens(emitter: *const Emitter, position: u32) ?struct { u32, u32 } {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.binary_lines) return null;

    const open = emit.ahead_of(emitter, position) orelse return null;
    if (!wrapped_paren(emitter, open)) return null;

    const close = join.closing_of(emitter, open) orelse return null;

    assert(open < close);

    if (emit.ahead_of(emitter, close)) |held| {
        if (!emitter.tokens[held].is_punctuation(.semicolon)) return null;
    }

    if (call.binary_floor(emitter, open, close) == call.binary_level_max) return null;
    return .{ open, close };
}

pub fn wrapping(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.return_parens) return null;
    if (emitter.line_first != position) return null;
    if (!words_contain(wrapped_words, emitter.tokens[position].text(emitter.source))) return null;

    const head = emit.ahead_of(emitter, position) orelse return null;
    if (jsx.wrapped(emitter, head) != null) return null;

    const inner = wrapping_inner(emitter, position, head);
    const from = inner orelse head;

    if (inner == null) {
        if (comment.chained(emitter, head)) |end| return end;
    }

    const end, const operated = wrapping_end(emitter, from) orelse return null;

    if (!operated) return null;
    if (end == from) return null;
    if (wrapping_parted(emitter, from, end)) return null;
    return wrapping_tailed(emitter, end) orelse end;
}

fn wrapping_inner(emitter: *const Emitter, position: u32, head: u32) ?u32 {
    assert(position < head);
    assert(head < emitter.count);

    const open, const close = wrap_parens(emitter, position) orelse return null;
    if (open != head) return null;

    const closing = join.closing_of(emitter, head) orelse return null;
    if (closing != close) return null;
    return emit.ahead_of(emitter, open);
}

fn wrapping_tailed(emitter: *const Emitter, end: u32) ?u32 {
    assert(end < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const held = emit.ahead_of(emitter, end) orelse return null;
    const token = emitter.tokens[held];
    const blocked = wrapping_tailed_blocked(emitter, held);

    if (token.kind != .comment) return null;

    if (!std.mem.startsWith(u8, token.text(emitter.source), "//")) {
        if (!blocked) return null;
    }

    if (body.parts_at(emitter, end, held)) return null;
    return held;
}

fn wrapping_tailed_blocked(emitter: *const Emitter, held: u32) bool {
    assert(held < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const after = emit.ahead_of(emitter, held) orelse return true;

    assert(after > held);

    return emitter.tokens[after].is_punctuation(.semicolon);
}

fn wrapping_end(emitter: *const Emitter, head: u32) ?struct { u32, bool } {
    assert(head < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const sequenced = wrapping_sequence(emitter, head);
    var depth: u32 = 0;
    var end = head;
    var operated = false;
    var scan = head;

    while (scan < emitter.count) {
        const element = jsx_body(emitter, scan);

        if (element != null) {
            if (scan <= head) return null;
        }

        if (tmpl.template_body(emitter, scan) orelse element) |stop| {
            assert(stop >= scan);

            end = stop;
            scan = stop + 1;

            continue;
        }

        const token = emitter.tokens[scan];
        const kind = token.kind;

        if (depth == 0) {
            if (wrapping_end_ternary(emitter, scan, sequenced)) return null;
        }

        const skipped = kind == .newline or token.length == 0 or kind == .comment;

        if (skipped) {
            scan += 1;

            continue;
        }

        if (walk.is_open(kind)) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            if (depth == 0) break;

            depth -= 1;
        } else if (depth == 0) {
            if (kind.eql(.{ .punctuation = .semicolon })) break;
            if (wrapping_end_refused(emitter, scan, sequenced)) return null;

            if (wrapping_end_operates(emitter, scan)) operated = true;
        } else {}

        end = scan;
        scan += 1;
    }

    assert(end < emitter.count);

    return .{ end, operated };
}

fn wrapping_end_ternary(emitter: *const Emitter, scan: u32, sequenced: bool) bool {
    assert(scan < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (sequenced) return false;
    if (!walk.text_is(emitter.tokens[scan].text(emitter.source), "?")) return false;
    return !tern.optional(emitter, scan);
}

fn wrapping_end_refused(emitter: *const Emitter, scan: u32, sequenced: bool) bool {
    assert(scan < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (sequenced) return false;
    return words_contain(wrapped_refused, emitter.tokens[scan].text(emitter.source));
}

fn wrapping_end_operates(emitter: *const Emitter, scan: u32) bool {
    assert(scan < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (emitter.tokens[scan].is_punctuation(.comma)) {
        if (emitter.brackets.angles_at(scan) == 0) return true;
    }

    return wrapping_operator(emitter, scan);
}

fn wrapping_sequence(emitter: *const Emitter, head: u32) bool {
    assert(head < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var depth: u32 = 0;
    var scan = head;

    while (scan < emitter.count) {
        const token = emitter.tokens[scan];
        const skipped = tmpl.template_body(emitter, scan) orelse jsx_body(emitter, scan);

        if (skipped) |stop| {
            assert(stop >= scan);

            scan = stop + 1;

            continue;
        }

        const opens = walk.is_open(token.kind) or token.kind == .block_start;
        const closes = walk.is_close(token.kind) or token.kind == .block_end;

        if (opens) {
            depth += 1;
        } else if (closes) {
            if (depth == 0) return false;

            depth -= 1;
        } else if (depth == 0) {
            if (token.is_punctuation(.semicolon)) return false;

            if (token.is_punctuation(.comma)) {
                if (emitter.brackets.angles_at(scan) == 0) return true;
            }
        } else {}

        scan += 1;
    }

    return false;
}

fn wrapping_parted(emitter: *const Emitter, head: u32, end: u32) bool {
    assert(head <= end);
    assert(end < emitter.count);

    var depth: u32 = 0;
    var opened = false;
    var previous = head;
    var scan = head;

    while (scan <= end) {
        if (tmpl.template_body(emitter, scan) orelse jsx_body(emitter, scan)) |stop| {
            assert(stop >= scan);

            previous = stop;
            scan = stop + 1;

            continue;
        }

        const token = emitter.tokens[scan];
        const skipped = token.kind == .newline or token.length == 0;

        if (skipped) {
            scan += 1;

            continue;
        }

        if (token.kind == .comment) {
            opened = true;
            scan += 1;

            continue;
        }

        if (scan > head) {
            if (wrapping_parted_breaks(emitter, head, previous, scan, depth, opened)) return true;
        }

        if (walk.is_open(token.kind)) {
            depth += 1;
        } else if (walk.is_close(token.kind)) {
            depth -|= 1;
        } else {}

        opened = false;
        previous = scan;
        scan += 1;
    }

    return false;
}

fn wrapping_parted_breaks(
    emitter: *const Emitter,
    head: u32,
    previous: u32,
    scan: u32,
    depth: u32,
    opened: bool,
) bool {
    assert(head < scan);
    assert(previous < scan);
    assert(depth < std.math.maxInt(u32));

    const before = emitter.tokens[previous];
    const sequenced = before.is_punctuation(.comma);
    const branched = branch_seat(emitter, scan) or branch_seat(emitter, previous);

    const operated = emitter.policy.binary_lines and
        wrapping_parted_operated(emitter, previous, scan, depth, sequenced, branched);

    const commented = before.kind == .comment or opened;
    const angled = emitter.brackets.angles_at(scan) > emitter.brackets.angles_at(head);
    const listed = depth > 0 or angled;
    const chained = emit.is_dot(emitter, scan);

    if (commented) return false;
    if (listed) return false;
    if (chained) return false;
    if (body.parted_by(emitter, before.end(), emitter.tokens[scan].offset) == 0) return false;
    if (operated) return false;
    return !binary_leveled(emitter, previous);
}

fn wrapping_parted_operated(
    emitter: *const Emitter,
    previous: u32,
    scan: u32,
    depth: u32,
    sequenced: bool,
    branched: bool,
) bool {
    assert(previous < scan);
    assert(scan < emitter.count);

    if (depth == 0) {
        if (sequenced) return true;
        if (wrapping_operator(emitter, scan)) return true;
    }

    if (branched) return true;
    return wrapping_operator(emitter, previous);
}

pub fn assign_breaks(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.hug_lasts) return false;

    var depth: u32 = 0;
    var scan = position + 1;

    while (scan < emitter.count) {
        if (tmpl.template_body(emitter, scan) orelse jsx_body(emitter, scan)) |stop| {
            assert(stop >= scan);

            scan = stop + 1;

            continue;
        }

        const token = emitter.tokens[scan];

        if (walk.is_open(token.kind)) {
            depth += 1;
        } else if (walk.is_close(token.kind)) {
            if (depth == 0) return false;

            depth -= 1;
        } else if (depth == 0) {
            if (assign_breaks_stops(emitter, scan)) return false;
            if (wrapping_operator(emitter, scan)) return true;
        } else {}

        scan += 1;
    }

    return false;
}

fn assign_breaks_stops(emitter: *const Emitter, scan: u32) bool {
    assert(scan < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const text = emitter.tokens[scan].text(emitter.source);
    if (walk.text_is(text, ";")) return true;
    if (walk.text_is(text, "=>")) return true;
    if (!walk.text_is(text, "?")) return false;
    return !tern.optional(emitter, scan);
}

fn wrapping_operand(emitter: *const Emitter, held: u32) bool {
    assert(held < emitter.count);

    const token = emitter.tokens[held];

    switch (token.kind) {
        .identifier, .number, .string => return true,
        else => {},
    }

    if (walk.is_close(token.kind)) return true;
    if (token.kind == .block_end) return true;
    if (!emitter.policy.chain_simples) return false;
    return line.word_is(emitter, held, wrapping_words);
}

pub fn wrapping_operator(emitter: *const Emitter, spelled: u32) bool {
    assert(spelled < emitter.count);

    if (core.memo_found(emitter, .wrapping_operator, spelled, 0)) |answer| return answer == 1;

    const held = wrapping_operator_scanned(emitter, spelled);

    core.memo_store(emitter, .wrapping_operator, spelled, 0, @intFromBool(held));

    return held;
}

fn wrapping_operator_scanned(emitter: *const Emitter, spelled: u32) bool {
    assert(spelled < emitter.count);

    const position = comment.shift_head(emitter, spelled);

    assert(position < emitter.count);

    if (!wrapping_spelled(emitter, position)) return false;

    var before = emit.back_of(emitter, position);

    for (0..wrapping_comment_max) |_| {
        const held = before orelse break;
        if (emitter.tokens[held].kind != .comment) break;

        before = emit.back_of(emitter, held);
    }

    const held = before orelse return false;
    if (list.mapped_closed(emitter, held)) return false;

    if (wrapping_operand(emitter, held)) {
        if (!edge.statement_signed(emitter, position, held)) return true;
    }

    return wrapping_suffixed(emitter, held);
}

pub fn wrapping_spelled(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);

    if (emitter.tokens[position].kind == .string) return false;

    const text = emitter.tokens[position].text(emitter.source);
    if (words_contain(wrapped_operators, text)) return true;
    if (words_contain(emitter.policy.wrap_words, text)) return true;
    if (shift_width(emitter, position) >= 2) return true;
    if (comparing(emitter, position)) return true;
    if (!words_contain(bitwise_operators, text)) return false;
    if (emitter.brackets.angles_at(position) != 0) return false;
    if (bitwise_valued(emitter, position)) return true;
    return bitwise_untyped(emitter, position);
}

fn wrapping_suffixed(emitter: *const Emitter, held: u32) bool {
    assert(held < emitter.count);

    const text = emitter.tokens[held].text(emitter.source);
    const nonnull = emitter.policy.type_words.len > 0 and walk.text_is(text, "!");
    const postfix = emitter.policy.chain_simples and words_contain(postfix_words, text);

    if (nonnull) {
        if (emit.back_of(emitter, held)) |found| {
            if (wrapping_operand(emitter, found)) return true;
        }
    }

    if (postfix) {
        if (emit.back_of(emitter, held)) |found| {
            if (wrapping_operand(emitter, found)) return true;
        }
    }

    return false;
}

pub fn union_returned(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    if (!emitter.policy.union_parts) return false;
    if (!emitter.tokens[open].kind.eql(.{ .punctuation = .paren_open })) return false;

    const colon = emit.ahead_of(emitter, close) orelse return false;
    if (!emitter.tokens[colon].kind.eql(.{ .punctuation = .colon })) return false;

    const coded = line.coding(emitter, colon) orelse return false;

    if (list.signature_grouped(emitter, open, close)) return false;

    const held = union_of(emitter, coded) orelse return false;
    if (held.open != colon) return false;
    return union_wide(emitter, &held);
}

pub fn spread_matrix(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    if (!emitter.policy.hug_lasts) return false;
    if (!emitter.tokens[open].is_punctuation(.bracket_open)) return false;

    var rows: u32 = 0;
    var held: ?Token.Kind = null;
    var scan = spread_within(emitter, open, close);

    while (scan) |head| {
        assert(head > open);
        assert(head < close);

        const kind = emitter.tokens[head].kind;
        const nested = kind == .block_start or kind.eql(.{ .punctuation = .bracket_open });
        if (!nested) return false;

        if (held) |item| {
            if (!item.eql(kind)) return false;
        }

        const stop = join.closing_of(emitter, head) orelse return false;
        if (stop >= close) return false;
        if (spread_items(emitter, head, stop) < 2) return false;

        held = kind;
        rows += 1;
        scan = spread_next(emitter, stop, close);
    }

    return rows > 1;
}

fn spread_within(emitter: *const Emitter, open: u32, close: u32) ?u32 {
    assert(open < close);
    assert(close < emitter.count);

    const held = emit.ahead_of(emitter, open) orelse return null;
    if (held >= close) return null;

    assert(held > open);

    return held;
}

fn spread_next(emitter: *const Emitter, stop: u32, close: u32) ?u32 {
    assert(stop < close);
    assert(close < emitter.count);

    const after = spread_within(emitter, stop, close) orelse return null;
    if (!emitter.tokens[after].is_punctuation(.comma)) return null;
    return spread_within(emitter, after, close);
}

fn spread_items(emitter: *const Emitter, open: u32, close: u32) u32 {
    assert(open < close);
    assert(close < emitter.count);

    var items: u32 = 0;
    var depth: u32 = 0;
    var scan = open + 1;
    var written = false;

    while (scan < close) {
        const kind = emitter.tokens[scan].kind;
        const edged = depth == 0 and kind.eql(.{ .punctuation = .comma });

        if (walk.is_open(kind)) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            depth -|= 1;
        } else if (edged) {
            items += @intFromBool(written);
            written = false;
            scan += 1;

            continue;
        } else {}

        written = written or (emitter.tokens[scan].length > 0 and kind != .newline);
        scan += 1;
    }

    assert(scan >= close);

    return items + @intFromBool(written);
}

pub fn spread_rest(emitter: *const Emitter, close: u32) bool {
    assert(close < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const rests = words_contain(emitter.policy.prefix_words, "...") and
        emitter.tokens[close].is_punctuation(.paren_close);

    if (!rests) return false;

    const open = emitter.brackets.open_of(close) orelse return false;

    if (emitter.policy.rest_binds) {
        if (!bind.bound_pattern(emitter, close)) return false;
    }

    var depth: u32 = 0;
    var head: ?u32 = null;
    var scan = open + 1;

    while (scan < close) {
        const kind = emitter.tokens[scan].kind;

        const edged = depth == 0 and emitter.tokens[scan].is_punctuation(.comma) and
            emitter.brackets.angles_at(scan) == 0;

        if (walk.is_open(kind)) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            depth -|= 1;
        } else if (edged) {
            head = emit.ahead_of(emitter, scan);
        } else {
            const unheaded = head == null and kind != .newline and emitter.tokens[scan].length > 0;

            if (unheaded) head = scan;
        }

        scan += 1;
    }

    var held = head orelse return false;

    while (emitter.tokens[held].kind == .comment) {
        held = emit.ahead_of(emitter, held) orelse return false;
    }

    return walk.text_is(emitter.tokens[held].text(emitter.source), "...");
}

pub fn chain_expanded(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.chain_groups) return false;
    if (!link.chain_linked(emitter, position)) return false;

    const head = link.chain_start(emitter, position) orelse return false;
    const stop = link.chain_stop(emitter, head) orelse return false;

    if (!call.chain_composed(emitter, head, stop)) {
        if (!link.chain_suffixed(emitter, head, stop)) return false;
    }

    var links: [chain_link_max]u32 = @splat(0);
    const groups = link.chain_groups(emitter, head, stop, &links);
    const merges = chain_merges(emitter, head, &links, groups);
    const cutoff: u32 = if (merges) 3 else 2;
    const from: u32 = @intFromBool(merges);

    assert(groups <= chain_link_max);

    if (groups < cutoff) {
        if (!link.chain_suffixed(emitter, head, stop)) return false;
    }

    for (links[from..groups]) |held| {
        if (held == position) return true;
    }

    return false;
}

pub fn chain_merges(emitter: *const Emitter, head: u32, links: []const u32, groups: u32) bool {
    assert(head < emitter.count);
    assert(groups <= links.len);

    if (groups < 2) return false;

    const text = emitter.tokens[head].text(emitter.source);
    const factory = chain_merges_factory(emitter, head, text);
    const before = emit.back_of(emitter, links[0]);
    if (before == head) return factory;

    const held = before orelse return false;
    return chain_merges_named(emitter.tokens[held].text(emitter.source));
}

fn chain_merges_factory(emitter: *const Emitter, head: u32, text: []const u8) bool {
    assert(head < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (chain_merges_named(text)) return true;

    if (emitter.policy.chain_simples) {
        if (walk.text_is(text, "this")) return true;
    }

    if (!chain_leads(emitter, head)) return false;
    if (!chain_statement(emitter, head)) return false;
    return text.len <= emitter.options.indent_width;
}

fn chain_merges_named(name: []const u8) bool {
    assert(name.len <= std.math.maxInt(u32));

    if (name.len == 0) return false;
    if (std.ascii.isUpper(name[0])) return true;

    for (name) |byte| {
        const marked = byte == '_' or byte == '$';
        if (!marked) return false;
    }

    assert(name.len > 0);

    return true;
}

fn chain_leads(emitter: *const Emitter, head: u32) bool {
    assert(head < emitter.count);
    assert(emitter.line_first <= emitter.count);

    if (emitter.line_first == head) return true;

    const found = join.line_lead(emitter, head) orelse return false;
    return found[0] == head;
}

fn chain_statement(emitter: *const Emitter, head: u32) bool {
    assert(head < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const held = comment.back(emitter, head) orelse return true;
    const kind = emitter.tokens[held].kind;
    if (kind == .block_end) return true;
    if (kind == .block_start) return true;
    return kind.eql(.{ .punctuation = .semicolon });
}

pub fn chain_calls(emitter: *const Emitter, head: u32, stop: u32) u32 {
    assert(head <= stop);
    assert(stop < emitter.count);

    var calls: u32 = 0;
    var scan = head;

    while (scan <= stop) {
        const kind = emitter.tokens[scan].kind;

        if (walk.is_open(kind)) {
            calls += @intFromBool(kind.eql(.{ .punctuation = .paren_open }));
            scan = (join.closing_of(emitter, scan) orelse stop) + 1;

            continue;
        }

        scan += 1;
    }

    assert(calls <= stop - head + 1);

    return calls;
}

pub fn member_newed(emitter: *const Emitter, head: u32, dot: u32) bool {
    assert(head < emitter.count);
    assert(dot < emitter.count);

    const held = emit.back_of(emitter, head) orelse return false;
    if (!walk.text_is(emitter.tokens[held].text(emitter.source), "new")) return false;

    var scan = head;

    while (scan < dot) : (scan += 1) {
        if (emitter.tokens[scan].is_punctuation(.paren_open)) return false;
    }

    return true;
}

pub fn member_slight(emitter: *const Emitter, head: u32, stop: u32) bool {
    assert(head < emitter.count);
    assert(stop < emitter.count);

    const token = emitter.tokens[head];

    if (token.kind != .identifier) {
        if (!walk.text_is(token.text(emitter.source), "this")) return false;
    }

    const room = @divFloor(emitter.options.line_width, 4);
    var scan = head;

    while (scan <= stop) {
        const kind = emitter.tokens[scan].kind;

        if (!walk.is_open(kind)) {
            scan += 1;

            continue;
        }

        const close = join.closing_of(emitter, scan) orelse return false;

        assert(close > scan);

        if (kind.eql(.{ .punctuation = .paren_open })) {
            if (!member_slight_call(emitter, scan, close, room)) return false;
        }

        scan = close + 1;
    }

    return !link.member_call_chain(emitter, head);
}

fn member_slight_call(emitter: *const Emitter, open: u32, close: u32, room: u32) bool {
    assert(open < close);
    assert(close < emitter.count);

    if (!list.calling(emitter, open)) return true;

    const from = emit.ahead_of(emitter, open) orelse return true;
    if (from >= close) return true;

    const signed = list.slight(emitter, open, close);
    const alone = emit.ahead_of(emitter, from) == close;

    if (!alone) {
        if (!signed) return false;
    }

    const argument = emitter.tokens[from];

    if (!signed) {
        if (walk.columns(emitter.source, argument.offset, argument.end()) > room) return false;
    }

    return true;
}

fn member_operand(emitter: *const Emitter, head: u32, stop: u32) bool {
    assert(head <= stop + 1);
    assert(stop < emitter.count);

    var depth: u32 = 0;
    var scan = head;

    while (scan <= stop) {
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
            if (member_operand_operator(emitter, scan)) return true;
        } else {}

        scan += 1;
    }

    return false;
}

fn member_operand_operator(emitter: *const Emitter, scan: u32) bool {
    assert(scan < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (wrapping_operator(emitter, scan)) return true;
    if (!walk.text_is(emitter.tokens[scan].text(emitter.source), "?")) return false;
    return !tern.optional(emitter, scan);
}

fn chain_arrow_seated(emitter: *const Emitter, head: u32) bool {
    assert(head < emitter.count);
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    if (emitter.wraps_owed == 0) return false;

    const held = emitter.wrapped[wrap.run_top(emitter)];

    const kinded = switch (held.wrap) {
        .bodied, .hugged => true,
        else => false,
    };

    if (!kinded) return false;
    if (held.depth != emitter.depth) return false;
    if (head > held.close) return false;
    if (emit.back_of(emitter, head) == held.start) return true;
    return sole.body_operand(emitter, head, held.start);
}

fn chain_head_widened(emitter: *const Emitter, head: u32, stop: u32, headline: u32) u32 {
    assert(head <= stop);
    assert(stop < emitter.count);
    assert(headline < std.math.maxInt(u32));

    return chain_widened(emitter, head, @min(headline, stop));
}

pub fn chain_widened(emitter: *const Emitter, head: u32, stop: u32) u32 {
    assert(stop < emitter.count);
    assert(emitter.count == emitter.tokens.len);
    assert(head < emitter.count);

    var widened: u32 = 0;
    var scan = head;

    while (scan <= stop) {
        widened += 2 * @as(u32, @intFromBool(list.arrowed(emitter, scan)));
        scan += 1;
    }

    assert(scan > stop);

    return widened;
}

pub fn binary_spread(emitter: *const Emitter, position: u32, previous: u32) bool {
    assert(position < emitter.count);
    assert(previous < emitter.count);

    if (emitter.tokens[position].length == 0) return false;
    if (shifted_pair(emitter, previous, position)) return false;

    const head, const stop = binary_held(emitter, previous, true) orelse return false;
    return binary_wide(emitter, head, stop);
}

fn header_wide(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const end = call.valued_semicolon(emitter, position) orelse return true;
    return header_over(emitter, end, 0);
}

pub fn header_over(emitter: *const Emitter, end: u32, bound: u32) bool {
    assert(end < emitter.count);
    assert(emitter.line_first <= emitter.count);

    const level = link.led_level(emitter);
    const width = printed_columns(emitter, emitter.line_first, end) + clause.header_aligns(emitter);

    return (level -| bound) * emitter.options.indent_width + width > emitter.options.line_width;
}

fn binary_owed(emitter: *const Emitter, plain: bool) u32 {
    assert(emitter.wraps_owed <= core.wrap_depth_max);
    assert(emitter.count == emitter.tokens.len);

    const inherited = if (plain) lead.led_owed(emitter) else 0;
    const returned = @max(wrap_levels(emitter), inherited) + lead.wide_wraps(emitter);

    assert(returned < std.math.maxInt(u32));

    return returned;
}

fn statement_bodied(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    const opened = walk.is_open(emitter.tokens[position].kind);
    const lowered = opened and emitter.depth > 0;
    const depth = emitter.depth - @intFromBool(lowered);
    if (depth == 0) return true;
    return emitter.nest[depth - 1].bodied;
}

fn statement_runs(emitter: *const Emitter, position: u32) ?bool {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    const before = emit.back_of(emitter, position) orelse {
        if (position == emitter.line_first) return false;
        return null;
    };

    const held = emitter.tokens[before].kind;
    const frame = run_frame(emitter, position);
    const sequenced = statement_runs_sequenced(emitter, before, frame);
    const leading = sequenced and before == frame.open;

    if (position != emitter.line_first) {
        if (leading) return true;
        if (statement_exported(emitter, position)) return false;
        return null;
    }

    const statement = statement_runs_statement(emitter, position, before);
    const bodied = statement_bodied(emitter, position) and held.eql(.{ .punctuation = .comma });

    const claused = statement_bodied(emitter, position) and
        statement_runs_claused(emitter, before);

    if (statement) return sequenced;
    if (sequenced) return sequenced;
    if (bodied) return sequenced;
    if (claused) return sequenced;
    return null;
}

fn statement_runs_sequenced(emitter: *const Emitter, before: u32, frame: Frame) bool {
    assert(before < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.depth == 0) return false;
    if (!frame.kind.eql(.{ .punctuation = .paren_open })) return false;
    if (list.calling(emitter, frame.open)) return false;
    if (split.headed(emitter, frame.open)) return false;

    const listed = before == frame.open or emitter.tokens[before].is_punctuation(.comma);
    if (!listed) return false;
    return sequenced_frame(emitter, frame);
}

fn statement_runs_statement(emitter: *const Emitter, position: u32, before: u32) bool {
    assert(before < position);
    assert(position < emitter.count);

    if (!statement_bodied(emitter, position)) return false;

    const held = emitter.tokens[before].kind;
    if (held == .block_start) return true;
    if (held == .block_end) return true;
    if (held.eql(.{ .punctuation = .semicolon })) return true;
    if (!held.eql(.{ .punctuation = .colon })) return false;
    return split.armed(emitter, before);
}

fn statement_runs_claused(emitter: *const Emitter, before: u32) bool {
    assert(before < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (emitter.tokens[before].is_punctuation(.paren_close)) {
        if (emit.opened(emitter, before)) |open| {
            if (split.headed(emitter, open)) return true;
        }
    }

    if (!emitter.policy.chain_simples) return false;
    return line.word_is(emitter, before, clause_word_bodies);
}

fn statement_wide(emitter: *const Emitter, position: u32, end: u32) bool {
    assert(position < emitter.count);
    assert(end < emitter.count);

    const width = emitter.options.line_width;
    const indent = emitter.options.indent_width;
    const exported = statement_exported(emitter, position);
    const sequenced = position != emitter.line_first and !exported;

    if (sequenced) {
        const from, const level, const led = bind.sequence_seated(emitter, position) orelse
            return false;

        const spreads = if (led) 0 else lead.spread_levels(emitter);
        return (level + spreads) * indent + printed_columns(emitter, from, end) > width;
    }

    const level = wrap.header_led(emitter);
    const aligned = lead.ternary_align_columns(emitter);
    const from = if (exported) emitter.line_first else position;

    return level * indent + aligned + printed_columns(emitter, from, end) > width;
}

fn statement_exported(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.line_first < emitter.count);

    if (position == emitter.line_first) return false;

    const word = join.coded_before(emitter, position) orelse return false;
    if (!walk.text_is(emitter.tokens[word].text(emitter.source), "default")) return false;

    const exporting = join.coded_before(emitter, word) orelse return false;

    assert(exporting < word);

    if (exporting != emitter.line_first) return false;
    if (!walk.text_is(emitter.tokens[exporting].text(emitter.source), "export")) return false;
    return statement_bodied(emitter, position);
}

fn statement_wrapped(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    const opened = walk.is_open(emitter.tokens[position].kind);
    const lowered = opened and emitter.depth > 0;
    const depth = emitter.depth - @intFromBool(lowered);
    const sequenced = statement_wrapped_sequenced(emitter, position);

    for (emitter.wrapped[0..emitter.wraps_owed]) |held| {
        if (held.depth < depth) continue;

        const parenthesized = held.wrap == .parens and held.depth == depth;

        if (sequenced) {
            if (parenthesized) continue;
        }

        return true;
    }

    return false;
}

fn statement_wrapped_sequenced(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const held = emit.back_of(emitter, position) orelse return false;
    return emitter.tokens[held].is_punctuation(.comma);
}

fn chain_branch(emitter: *const Emitter, leader: u32) struct { ?u32, bool } {
    assert(leader < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const before = emit.back_of(emitter, leader);
    const commented = chain_branch_commented(emitter, before);
    const candidate = if (commented) join.coded_before(emitter, leader) else before;
    const branch = chain_branch_seat(emitter, candidate);

    return .{ branch, commented and branch != null };
}

fn chain_branch_commented(emitter: *const Emitter, before: ?u32) bool {
    assert(emitter.count == emitter.tokens.len);
    if (before) |held| assert(held < emitter.count);

    const held = before orelse return false;
    const token = emitter.tokens[held];

    assert(held < emitter.count);

    if (token.kind != .comment) return false;
    return std.mem.startsWith(u8, token.text(emitter.source), "//");
}

fn chain_branch_seat(emitter: *const Emitter, candidate: ?u32) ?u32 {
    assert(emitter.count == emitter.tokens.len);
    if (candidate) |held| assert(held < emitter.count);

    const held = candidate orelse return null;

    assert(held < emitter.count);

    if (!branch_seat(emitter, held)) return null;
    if (!tern.ternary_parted(emitter, held)) return null;
    return held;
}

fn chain_line_seat(emitter: *const Emitter, head: u32) struct { u32, u32 } {
    assert(head < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (lead.spread_item_seat(emitter, head)) |found| {
        return link.chain_seat(emitter, head, found[0], found[1]);
    }

    const from, const level_at = lead.spread(emitter, head) orelse
        lead.spread_item(emitter, head) orelse
        join.line_lead(emitter, head) orelse
        .{ emitter.line_first, emitter.printed };

    const level = level_at + lead.spread_levels(emitter) + lead.chain_levels(emitter);
    const lined = chain_line_seat_lined(emitter, head, from);
    const led = if (lined) @max(level, link.line_led(emitter, head) orelse level) else level;

    return link.chain_seat(emitter, head, from, led -| chain_line_bound(emitter, from));
}

fn chain_line_bound(emitter: *const Emitter, from: u32) u32 {
    assert(from < emitter.count);
    assert(emitter.lined < core.line_level_max);

    const ring = emitter.bound_ring orelse return 0;
    const found = line.at(emitter, from) orelse return 0;
    if (ring.start != found.start) return 0;
    if (found.start - 1 != from) return 0;
    assert(found.level -| ring.level < std.math.maxInt(u32));

    return found.level -| ring.level;
}

fn chain_line_seat_lined(emitter: *const Emitter, head: u32, from: u32) bool {
    assert(head < emitter.count);
    assert(from <= emitter.count);

    const found = join.line_lead(emitter, head) orelse return false;
    return found[0] == from;
}

pub fn wrapped_around(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    for (emitter.wrapped[0..emitter.wraps_owed]) |held| {
        if (position <= held.start) continue;
        if (position > held.close) continue;
        return true;
    }

    return false;
}

pub fn wrapped_run(emitter: *const Emitter, position: u32) bool {
    assert(position <= emitter.count);
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    for (emitter.wrapped[0..emitter.wraps_owed]) |held| {
        if (held.wrap != .parens) continue;
        if (position <= held.start) continue;
        if (position > held.close) continue;
        if (emitter.depth <= held.depth) return true;
    }

    return false;
}

fn typed_members(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const close = join.closing_of(emitter, open) orelse return false;
    var depth: u32 = 0;
    var scan = open + 1;

    while (scan < close) {
        if (tmpl.template_body(emitter, scan) orelse jsx_body(emitter, scan)) |end| {
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
            if (kind.eql(.{ .punctuation = .semicolon })) return true;
        } else {}

        scan += 1;
    }

    return false;
}

fn operand_tailed(emitter: *const Emitter, close: u32, operator: u32) bool {
    assert(close < emitter.count);
    assert(operator < emitter.count);

    _, const ended = binary_run(emitter, operator) orelse return false;

    if (ended <= operator) return false;

    const looser = call.operand_looser(emitter, operator, ended);
    const stop = looser orelse ended;
    const trailing = looser == null and operand_tailed_trails(emitter, stop);

    const width = printer_level(emitter) * emitter.options.indent_width +
        printed_columns(emitter, close, stop) + @intFromBool(trailing);

    return width <= emitter.options.line_width;
}

fn operand_tailed_trails(emitter: *const Emitter, stop: u32) bool {
    assert(stop < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const held = emit.ahead_of(emitter, stop) orelse return false;
    const token = emitter.tokens[held];
    if (token.is_punctuation(.comma)) return true;
    return token.is_punctuation(.semicolon);
}

fn arrow_body_grouped(emitter: *const Emitter, start: u32, close: u32) bool {
    assert(close < emitter.count);
    assert(emitter.count == emitter.tokens.len);
    assert(start < emitter.count);

    var depth: u32 = 0;
    var called = false;
    var named = true;
    var scan = start;

    while (scan < close) {
        const token = emitter.tokens[scan];
        const kind = token.kind;
        const opens = walk.is_open(kind) or kind == .block_start;
        const closes = walk.is_close(kind) or kind == .block_end;

        if (opens) {
            if (depth == 0) {
                if (kind.eql(.{ .punctuation = .paren_open })) called = true;
            }

            depth += 1;
        } else if (closes) {
            depth -|= 1;
        } else if (depth == 0) {
            const text = token.text(emitter.source);

            if (walk.text_is(text, "?")) {
                if (!tern.optional(emitter, scan)) return true;
            }

            if (walk.text_is(text, ",")) break;

            named = named and arrow_body_grouped_named(emitter, scan);
        } else {}

        scan += 1;
    }

    return called and named;
}

fn arrow_body_grouped_named(emitter: *const Emitter, scan: u32) bool {
    assert(scan < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const token = emitter.tokens[scan];
    if (token.kind == .identifier) return true;
    if (words_contain(arrow_body_names, token.text(emitter.source))) return true;
    return emit.is_dot(emitter, scan);
}

pub fn binary_seated(emitter: *const Emitter, head: u32) bool {
    assert(head < emitter.count);
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    if (emitter.wraps_owed == 0) return false;

    const held = emitter.wrapped[wrap.run_top(emitter)];

    const kinded = switch (held.wrap) {
        .argued, .paired, .parens, .valued => true,
        else => false,
    };

    if (!kinded) return false;
    if (held.depth != emitter.depth) return false;
    if (head > held.close) return false;

    const before = emit.back_of(emitter, link.chain_seated_at(emitter, head)) orelse return false;
    if (call.binary_floored(emitter, before, held.floor)) return true;
    return before == held.start;
}

pub fn member_typed(emitter: *const Emitter, head: u32, dot: u32) bool {
    assert(head < emitter.count);
    assert(dot < emitter.count);

    var depth: u32 = 0;
    var scan = head;

    while (scan < dot) {
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
            if (member_typed_word(emitter, scan)) return true;
        } else {}

        scan += 1;
    }

    return false;
}

fn member_typed_word(emitter: *const Emitter, scan: u32) bool {
    assert(scan < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!words_contain(member_type_words, emitter.tokens[scan].text(emitter.source))) return false;

    const held = emit.back_of(emitter, scan) orelse return true;
    return !emit.is_dot(emitter, held);
}

pub fn member_seated(
    emitter: *const Emitter,
    head: u32,
    from: u32,
    level: u32,
) ?struct { u32, u32 } {
    assert(head < emitter.count);
    assert(from < emitter.count);
    assert(level < std.math.maxInt(u32));

    var before = emit.back_of(emitter, head) orelse return null;
    var seat = head;

    if (emitter.tokens[before].is_punctuation(.assign)) {
        const target = edge.statement_head(emitter, before) orelse return null;
        const open = emit.back_of(emitter, target) orelse return null;
        if (open == from) return null;
        if (!emitter.tokens[open].is_punctuation(.paren_open)) return null;

        before = open;
    }

    for (0..member_prefix_max) |_| {
        if (!member_seated_prefixed(emitter, before)) break;

        seat = before;
        before = emit.back_of(emitter, before) orelse return null;
    }

    const close = member_seated_close(emitter, head, before) orelse return null;
    const width = level * emitter.options.indent_width + printed_columns(emitter, from, close);
    if (width <= emitter.options.line_width) return null;
    return .{ seat, member_seat_level(emitter, before) };
}

fn member_seated_prefixed(emitter: *const Emitter, before: u32) bool {
    assert(before < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const text = emitter.tokens[before].text(emitter.source);
    if (words_contain(member_prefixes, text)) return true;
    if (!walk.text_is(text, "(")) return false;
    return !list.calling(emitter, before);
}

fn member_seated_close(emitter: *const Emitter, head: u32, before: u32) ?u32 {
    assert(before < head);
    assert(head < emitter.count);

    const text = emitter.tokens[before].text(emitter.source);
    var branched = false;

    if (walk.text_is(text, ":")) branched = !member_property(emitter, before);

    if (!branched) {
        if (walk.text_is(text, "?")) branched = !tern.optional(emitter, before);
    }

    if (branched) return member_branched(emitter, head);
    if (!wrapping_operator(emitter, before)) return null;

    const run = binary_run(emitter, before) orelse return null;
    return run[1];
}

fn member_seat_level(emitter: *const Emitter, operator: u32) u32 {
    assert(operator < emitter.count);
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    if (emitter.wraps_owed == 0) {
        assert(emitter.printed + 1 < std.math.maxInt(u32));

        return emitter.printed + 1;
    }

    const top = wrap.run_top(emitter);
    const start = emitter.wrapped[top].start;
    const owned = member_seat_owned(emitter, operator, top);
    const led = link.line_led(emitter, start) orelse {
        assert(emitter.printed < std.math.maxInt(u32));

        return emitter.printed + 1;
    };

    if (!owned) {
        assert(emitter.printed + 1 < std.math.maxInt(u32));

        return emitter.printed + 1;
    }

    assert(led + 1 < std.math.maxInt(u32));

    return led + 1;
}

fn member_seat_owned(emitter: *const Emitter, operator: u32, top: u32) bool {
    assert(top < emitter.wraps_owed);
    assert(operator < emitter.count);

    const held = emitter.wrapped[top];
    if (held.wrap != .argued) return false;
    if (emitter.wraps_nested[top] != core.nest_none) return false;
    if (operator <= held.start) return false;
    if (operator >= held.close) return false;

    const found = join.line_lead(emitter, held.start) orelse return false;
    return found[0] == held.start;
}

fn member_branched(emitter: *const Emitter, head: u32) ?u32 {
    assert(head < emitter.count);
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    var index = emitter.wraps_owed;

    while (index > 0) {
        index -= 1;

        const held = emitter.wrapped[index];

        const branchy = switch (held.wrap) {
            .guarded, .nested, .ternary => true,
            else => false,
        };

        if (!branchy) continue;
        if (held.floor >= head) continue;
        if (held.start > head) continue;
        if (head > held.close) continue;
        return held.close;
    }

    return null;
}

fn member_valued(emitter: *const Emitter, head: u32, stop: u32) bool {
    assert(head < emitter.count);
    assert(stop < emitter.count);

    const colon = member_propertied(emitter, head) orelse return false;
    const end = member_property_end(emitter, colon);

    assert(end >= colon);

    if (member_slight(emitter, head, stop)) return true;
    return member_operand(emitter, colon + 1, end);
}

fn member_propertied(emitter: *const Emitter, head: u32) ?u32 {
    assert(head < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var scan = head;

    for (0..chain_scan_max) |_| {
        const before = emit.back_of(emitter, scan) orelse return null;
        const kind = emitter.tokens[before].kind;
        const closes = walk.is_close(kind) or kind == .block_end;
        const opens = walk.is_open(kind) or kind == .block_start;

        if (closes) {
            scan = emitter.brackets.open_of(before) orelse return null;

            continue;
        }

        if (opens) return null;

        const text = emitter.tokens[before].text(emitter.source);
        if (words_contain(member_property_stops, text)) return null;

        if (walk.text_is(text, ":")) {
            if (member_property(emitter, before)) return before;
        }

        scan = before;
    }

    return null;
}

fn member_property(emitter: *const Emitter, colon: u32) bool {
    assert(colon < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const named = emit.back_of(emitter, colon) orelse return false;

    const keyed = switch (emitter.tokens[named].kind) {
        .identifier, .number, .string => true,
        else => false,
    };

    if (!keyed) return false;

    const held = emit.back_of(emitter, named) orelse return false;
    const kind = emitter.tokens[held].kind;
    if (kind == .block_start) return true;
    return kind.eql(.{ .punctuation = .comma });
}

fn member_property_end(emitter: *const Emitter, colon: u32) u32 {
    assert(colon < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var end = colon;
    var scan = colon;

    for (0..chain_scan_max) |_| {
        const after = emit.ahead_of(emitter, scan) orelse break;

        if (tmpl.spanned_unit(emitter, after)) |stop| {
            end = stop;
            scan = stop;

            continue;
        }

        const kind = emitter.tokens[after].kind;
        const opens = walk.is_open(kind) or kind == .block_start;

        const stops = walk.is_close(kind) or kind == .block_end or
            kind.eql(.{ .punctuation = .comma });

        if (opens) {
            const close = join.closing_of(emitter, after) orelse break;

            end = close;
            scan = close;

            continue;
        }

        if (stops) break;

        end = after;
        scan = after;
    }

    assert(end >= colon);

    return end;
}

pub fn predicate_colon(emitter: *const Emitter, colon: u32) bool {
    assert(colon < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var subject = emit.ahead_of(emitter, colon) orelse return false;

    if (walk.text_is(emitter.tokens[subject].text(emitter.source), "asserts")) {
        subject = emit.ahead_of(emitter, subject) orelse return false;
    }

    const held = emit.ahead_of(emitter, subject) orelse return false;
    return walk.text_is(emitter.tokens[held].text(emitter.source), "is");
}

pub fn predicate_colon_of(emitter: *const Emitter, open: u32) ?u32 {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!walk.text_is(emitter.tokens[open].text(emitter.source), "is")) return null;

    const subject = emit.back_of(emitter, open) orelse return null;
    const before = emit.back_of(emitter, subject) orelse return null;
    var colon = before;

    if (walk.text_is(emitter.tokens[before].text(emitter.source), "asserts")) {
        colon = emit.back_of(emitter, before) orelse return null;
    }

    if (!emitter.tokens[colon].kind.eql(.{ .punctuation = .colon })) return null;

    assert(colon < open);

    return colon;
}

pub fn predicate_returned(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const colon = predicate_colon_of(emitter, open) orelse return false;
    const held = emit.back_of(emitter, colon) orelse return false;

    return emitter.tokens[held].kind.eql(.{ .punctuation = .paren_close });
}

const Bars = struct {
    angles: u32,
    bars: [union_member_max]u32,
    braced: bool,
    count: u32,
    depth: u32,
    stop: u32,
};

const BarsStep = enum { ended, refused, walked };

pub fn union_bars(
    emitter: *const Emitter,
    head: u32,
    annotated: bool,
) ?struct { [union_member_max]u32, bool, u32, u32 } {
    assert(head < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var state: Bars = .{
        .angles = 0,
        .bars = @splat(0),
        .braced = false,
        .count = 0,
        .depth = 0,
        .stop = head,
    };

    var scan = head;
    var ended = false;

    for (0..union_bars_scan_max) |_| {
        if (tmpl.template_body(emitter, scan)) |end| {
            state.stop = end;

            scan = emit.ahead_of(emitter, end) orelse {
                ended = true;

                break;
            };

            continue;
        }

        switch (union_bars_step(emitter, &state, scan, head, annotated)) {
            .ended => {
                ended = true;

                break;
            },
            .refused => return null,
            .walked => {},
        }

        const text = emitter.tokens[scan].text(emitter.source);

        const commented = emitter.tokens[scan].kind == .comment and
            std.mem.startsWith(u8, text, "//");

        if (!commented) state.stop = scan;

        scan = emit.ahead_of(emitter, scan) orelse {
            ended = true;

            break;
        };
    }

    assert(state.count <= union_member_max);

    if (state.count == 0) return null;
    if (!ended) return null;
    return .{ state.bars, state.braced, state.count, state.stop };
}

fn union_bars_step(
    emitter: *const Emitter,
    state: *Bars,
    scan: u32,
    head: u32,
    annotated: bool,
) BarsStep {
    assert(scan < emitter.count);
    assert(state.count <= union_member_max);
    assert(head < emitter.count);

    const kind = emitter.tokens[scan].kind;
    const opened = walk.is_open(kind) or kind == .block_start;
    const closed = walk.is_close(kind) or kind == .block_end;

    if (opened) {
        if (union_bars_bodied(emitter, state, scan, head, annotated)) return .ended;

        state.braced = state.braced or kind == .block_start;
        state.depth += 1;

        return .walked;
    }

    if (closed) {
        if (state.depth == 0) return .ended;

        state.depth -= 1;

        return .walked;
    }

    if (state.depth > 0) return .walked;
    return union_bars_level(emitter, state, scan);
}

fn union_bars_bodied(
    emitter: *const Emitter,
    state: *const Bars,
    scan: u32,
    head: u32,
    annotated: bool,
) bool {
    assert(scan < emitter.count);
    assert(head <= scan);

    const before = emit.back_of(emitter, scan);

    const barred = if (before) |held|
        walk.text_is(emitter.tokens[held].text(emitter.source), "|")
    else
        false;

    const membered = scan == head or barred;

    if (!annotated) return false;
    if (unite.union_arrow_head(emitter, scan, head)) return false;
    if (state.depth != 0) return false;
    if (emitter.tokens[scan].kind != .block_start) return false;
    if (body.bodied_brace(emitter, scan)) return true;
    if (state.angles != 0) return false;
    return !membered;
}

fn union_bars_level(emitter: *const Emitter, state: *Bars, scan: u32) BarsStep {
    assert(scan < emitter.count);
    assert(state.depth == 0);

    const text = emitter.tokens[scan].text(emitter.source);

    if (walk.text_is(text, "<")) {
        state.angles += 1;

        return .walked;
    }

    if (walk.text_is(text, ">")) {
        if (state.angles == 0) return .ended;

        state.angles -= 1;

        return .walked;
    }

    if (state.angles != 0) return .walked;
    if (union_bars_ending(emitter, scan)) return .ended;
    if (walk.text_is(text, "extends")) return .refused;

    if (walk.text_is(text, "|")) {
        if (state.count == union_member_max) return .refused;

        state.bars[state.count] = scan;
        state.count += 1;
    }

    return .walked;
}

fn union_bars_ending(emitter: *const Emitter, scan: u32) bool {
    assert(scan < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const kind = emitter.tokens[scan].kind;
    if (kind.eql(.{ .punctuation = .comma })) return true;
    if (kind.eql(.{ .punctuation = .semicolon })) return true;
    if (kind.eql(.{ .punctuation = .assign })) return true;
    if (walk.text_is(emitter.tokens[scan].text(emitter.source), "=>")) return true;
    return unite.union_branch_end(emitter, scan);
}

pub fn union_hugs(
    emitter: *const Emitter,
    head: u32,
    bars: *const [union_member_max]u32,
    count: u32,
    stop: u32,
) bool {
    assert(head < emitter.count);
    assert(count <= union_member_max);
    assert(stop <= emitter.count);

    var named = false;
    var voided: u32 = 0;
    var from = head;
    var index: u32 = 0;

    while (index <= count) : (index += 1) {
        const to = if (index == count) stop else emit.back_of(emitter, bars[index]) orelse stop;
        const text = emitter.tokens[from].text(emitter.source);
        const nulled = walk.text_is(text, "void") or walk.text_is(text, "null");
        const voids = from == to and nulled;

        if (voids) {
            voided += 1;
        } else if (union_hugs_named(emitter, from, to)) {
            named = true;
        } else {}

        const bar = emit.ahead_of(emitter, to) orelse break;

        from = emit.ahead_of(emitter, bar) orelse break;
    }

    assert(voided <= count + 1);

    return named and voided == count;
}

fn union_hugs_named(emitter: *const Emitter, from: u32, to: u32) bool {
    assert(from < emitter.count);
    assert(to < emitter.count);

    const braced = emitter.tokens[from].kind == .block_start and
        emitter.tokens[to].kind == .block_end;

    if (braced) return true;
    if (emitter.tokens[to].kind == .identifier) return true;
    return walk.text_is(emitter.tokens[to].text(emitter.source), ">");
}

fn union_line_level(emitter: *const Emitter, opens: u32) u32 {
    assert(opens < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    return link.line_led(emitter, opens) orelse emitter.levels;
}

pub fn union_seat(emitter: *const Emitter, held: *const Union) struct { u32, u32 } {
    assert(held.open < emitter.count);
    assert(held.head < emitter.count);

    if (union_seat_commented(emitter, held)) |head| {
        const lined = line_opened(emitter, held.open) orelse union_head(emitter, held.open);
        return .{ head, union_line_level(emitter, lined) };
    }

    if (emitter.depth > 0) {
        if (union_seat_itemed(emitter, held)) |seat| return seat;
        if (union_seat_membered(emitter, held)) |seat| return seat;
    }

    if (unite.union_listed(emitter, held.open)) return union_seat_listed(emitter, held);

    const opens = line_opened(emitter, held.open) orelse union_head(emitter, held.open);
    const level = union_line_level(emitter, opens);

    if (emit.back_of(emitter, held.open)) |name| {
        if (bind.declares_later(emitter, name)) return .{ name, level + 1 };
    }

    if (own.alias_parted(emitter, held.open, opens, level)) |close| return .{ close, level };
    return .{ opens, level };
}

fn union_seat_commented(emitter: *const Emitter, held: *const Union) ?u32 {
    assert(held.open < emitter.count);
    assert(held.head < emitter.count);

    const noted = emit.ahead_of(emitter, held.open) orelse return null;
    const first = held.lead orelse held.head;

    if (emitter.tokens[noted].kind != .comment) return null;
    if (!emitter.tokens[held.open].is_punctuation(.colon)) return null;
    if (!emit.roled(emitter, held.open, brace.role_type)) return null;
    if (emit.ahead_of(emitter, noted) != first) return null;
    if (!body.parts_at(emitter, noted, first)) return null;
    return first;
}

fn union_seat_itemed(emitter: *const Emitter, held: *const Union) ?struct { u32, u32 } {
    assert(emitter.depth > 0);
    assert(held.open < emitter.count);

    const frame = union_frame(emitter, held.open);
    if (!union_itemed(frame.kind)) return null;
    if (frame.spread == null) return null;
    if (frame.open >= held.open) return null;

    const tupled = frame.kind.eql(.{ .punctuation = .bracket_open });

    const level = if (tupled)
        @max(emitter.printed, emitter.levels) + spread_count(emitter) + wrap_levels(emitter)
    else
        union_seat_spread(emitter, held, &frame);

    if (unite.union_listed(emitter, held.open)) return .{ held.head, level + 1 };
    return .{ call.argument_start(emitter, frame.open, held.open), level };
}

fn union_seat_spread(emitter: *const Emitter, held: *const Union, frame: *const Frame) u32 {
    assert(frame.open < held.open);
    assert(held.open < emitter.count);

    const opens = line_opened(emitter, frame.open) orelse frame.open;
    var spread: u32 = 0;

    if (lead.spread(emitter, held.open)) |found| {
        if (found[0] < held.open) spread = found[1];
    } else if (frame.grouped) |grouped| {
        spread = emitter.shadow.inset_after(grouped) orelse 0;
    } else {}

    const lined = union_line_level(emitter, opens);
    const returned = @max((lead.item_led(emitter, frame.open) orelse lined) + 1, spread);

    assert(returned < std.math.maxInt(u32));

    return returned;
}

fn union_seat_membered(emitter: *const Emitter, held: *const Union) ?struct { u32, u32 } {
    assert(emitter.depth > 0);
    assert(held.open < emitter.count);

    const frame = union_frame(emitter, held.open);
    if (frame.open >= held.open) return null;
    if (!union_membered(emitter, &frame)) return null;

    const opens = line_opened(emitter, frame.open) orelse frame.open;
    const barred = unite.union_bar_step(emitter, frame.open, opens);

    const level = unite.union_item_level(emitter, frame, opens) orelse
        union_line_level(emitter, opens) + 1 + barred;

    if (unite.union_listed(emitter, held.open)) return .{ held.head, level + 1 };
    return .{ unite.union_member_start(emitter, frame.open, held.open), level };
}

fn union_seat_listed(emitter: *const Emitter, held: *const Union) struct { u32, u32 } {
    assert(held.open < emitter.count);
    assert(held.head < emitter.count);

    const opens = line_opened(emitter, held.open) orelse held.open;
    const angles = emitter.brackets.angles_at(held.open) -| emitter.brackets.angles_at(opens);
    const lists = @max(angles, 1);
    const level = union_line_level(emitter, opens) + lists;

    assert(lists >= 1);

    return .{ held.head, level };
}

pub fn union_columns(emitter: *const Emitter, from: u32, to: u32) u32 {
    assert(from <= emitter.count);
    assert(to <= emitter.count);

    return braced_columns(emitter, from, to);
}

pub fn spread_count(emitter: *const Emitter) u32 {
    assert(emitter.depth <= brace.nest_depth_max);
    assert(emitter.count == emitter.tokens.len);

    var spreads: u32 = 0;

    for (emitter.nest[0..emitter.depth]) |frame| {
        if (frame.spread == null) continue;
        if (spread_lambda(emitter, frame.open, frame.close, frame.kind)) continue;

        const hugged = frame.hugged > 0 and frame.hugged <= emitter.line_first;
        if (hugged) continue;

        spreads += 1;
    }

    assert(spreads <= emitter.depth);

    return spreads;
}

fn spread_lambda(emitter: *const Emitter, open: u32, close: u32, kind: Token.Kind) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!kind.eql(.{ .punctuation = .paren_open })) return false;
    if (close <= open) return false;

    const head = spread_within(emitter, open, close) orelse return false;

    if (wide.element_count(emitter, open, close) >= 2) return false;
    return call.functioned(emitter, head, close);
}

pub fn wrap_levels(emitter: *const Emitter) u32 {
    assert(emitter.wraps_owed <= core.wrap_depth_max);
    assert(emitter.line_first <= emitter.count);

    var levels: u32 = 0;

    for (emitter.wrapped[0..emitter.wraps_owed]) |held| {
        if (held.start < emitter.line_first) levels += 1;
    }

    assert(levels <= emitter.wraps_owed);

    return levels;
}

pub fn union_head(emitter: *const Emitter, position: u32) u32 {
    assert(position <= emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var scan = position;

    for (0..union_scan_max) |_| {
        const held = emit.back_of(emitter, scan) orelse break;
        const kind = emitter.tokens[held].kind;
        if (kind == .block_start) break;
        if (kind == .block_end) break;
        if (kind == .comment) break;
        if (kind.eql(.{ .punctuation = .semicolon })) break;

        scan = held;
    }

    assert(scan <= position);

    return scan;
}

pub fn owned_assign(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (binary_assigned(emitter, position)) return true;
    if (union_assigned(emitter, position)) return true;
    return assign_valued(emitter, position);
}

fn assign_valued(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.assign_values) return false;
    if (!own.assign_operator(emitter, position)) return false;

    const value = line.coding(emitter, position) orelse return false;
    const token = emitter.tokens[value];
    const text = token.text(emitter.source);
    const literal = token.kind == .number or words_contain(&.{ "class", "false", "true" }, text);
    const templated = token.kind == .string and std.mem.startsWith(u8, text, "`");

    if (!literal) {
        if (!templated) return false;
    }

    const close = tmpl.template_body(emitter, value) orelse
        own.bodied_of(emitter, value) orelse value;

    if (emit.ahead_of(emitter, close)) |after| {
        if (!emitter.tokens[after].kind.eql(.{ .punctuation = .semicolon })) return false;
    }

    return assign_narrow(emitter, position);
}

fn assign_narrow(emitter: *const Emitter, equals: u32) bool {
    assert(equals < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var scan = equals;

    for (0..union_scan_max) |_| {
        const held = emit.back_of(emitter, scan) orelse return true;
        const kind = emitter.tokens[held].kind;
        if (kind == .block_start) return true;
        if (kind == .block_end) return true;
        if (kind == .comment) return true;
        if (kind.eql(.{ .punctuation = .semicolon })) return true;
        if (assign_narrow_refused(emitter, held)) return false;

        const text = emitter.tokens[held].text(emitter.source);
        const angle = walk.text_is(text, "<") or walk.text_is(text, ">");
        const bracketed = walk.is_open(kind) or walk.is_close(kind);
        const stepped = bracketed or angle;

        if (stepped) {
            if (edge.header_closed(emitter, held, scan)) return true;

            scan = indexed_number(emitter, held) orelse return false;

            continue;
        }

        scan = held;
    }

    return false;
}

fn assign_narrow_refused(emitter: *const Emitter, held: u32) bool {
    assert(held < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const text = emitter.tokens[held].text(emitter.source);
    if (words_contain(narrow_modifier_words, text)) return true;
    if (link.asserted_member(emitter, held)) return true;
    if (walk.text_is(text, "|")) return true;
    return walk.text_is(text, "&");
}

fn indexed_number(emitter: *const Emitter, close: u32) ?u32 {
    assert(close < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.tokens[close].kind.eql(.{ .punctuation = .bracket_close })) return null;

    const open = emitter.brackets.open_of(close) orelse return null;
    const held = emit.ahead_of(emitter, open) orelse return null;
    if (emitter.tokens[held].kind != .number) return null;

    const after = emit.ahead_of(emitter, held) orelse return null;
    if (after != close) return null;

    assert(open < close);

    return open;
}

fn union_assigned(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.union_parts) return false;
    if (!emitter.tokens[position].kind.eql(.{ .punctuation = .assign })) return false;

    const after = emit.ahead_of(emitter, position) orelse return false;
    return unite.union_parted(emitter, after) != null;
}

fn run_frame(emitter: *const Emitter, position: u32) Frame {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    const opened = emitter.depth > 1 and
        walk.is_open(emitter.tokens[position].kind) and
        line.frame(emitter).open == position;

    if (opened) return emitter.nest[emitter.depth - 2];
    return line.frame(emitter);
}

fn sequenced_frame(emitter: *const Emitter, frame: Frame) bool {
    assert(frame.open < emitter.count);
    assert(frame.close <= emitter.count);

    var depth: u32 = 0;
    var scan = frame.open + 1;

    while (scan < frame.close) : (scan += 1) {
        const kind = emitter.tokens[scan].kind;
        const opens = walk.is_open(kind) or kind == .block_start or bind.spans_open(emitter, scan);
        const closes = walk.is_close(kind) or kind == .block_end;

        if (opens) {
            depth += 1;
        } else if (closes) {
            depth -|= 1;
        } else if (depth == 0) {
            if (emitter.tokens[scan].is_punctuation(.comma)) {
                if (emit.ahead_of(emitter, scan) != frame.close) return true;
            }
        } else {}
    }

    return false;
}

pub fn statement_stop(emitter: *const Emitter, head: u32) ?u32 {
    assert(head <= emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var depth: u32 = 0;
    var scan = head;

    while (scan < emitter.count) : (scan += 1) {
        const kind = emitter.tokens[scan].kind;
        const opens = walk.is_open(kind) or kind == .block_start or bind.spans_open(emitter, scan);
        const closes = walk.is_close(kind) or kind == .block_end;

        if (opens) {
            depth += 1;
        } else if (closes) {
            if (depth == 0) return null;

            depth -= 1;
        } else if (depth == 0) {
            const stops = emitter.tokens[scan].is_punctuation(.comma) or
                emitter.tokens[scan].is_punctuation(.semicolon);

            if (stops) return scan;
        } else {}
    }

    return null;
}

pub fn binary_nested(emitter: *const Emitter, previous: u32) bool {
    assert(previous < emitter.count);
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    if (emitter.wraps_owed == 0) return false;

    const top = emitter.wraps_owed - 1;
    const nest = emitter.wraps_nested[top];
    const unbare = nest != core.nest_bare and nest != core.nest_none;
    if (unbare) return false;

    const held = emitter.wrapped[top];

    const nestable = held.wrap == .argued or held.wrap == .paired or held.wrap == .parens or
        held.wrap == .valued or held.wrap == .bodied;

    if (!nestable) return false;
    if (held.floor == call.binary_level_max) return false;
    if (previous <= held.start) return false;
    if (previous > held.close) return false;
    if (!wrapping_operator(emitter, previous)) return false;

    const bracketed = binary_nested_bracketed(emitter, held.depth);
    if (bracketed) return false;
    return call.binary_level(emitter.tokens[previous].text(emitter.source)) > held.floor;
}

fn binary_nested_bracketed(emitter: *const Emitter, seated: u32) bool {
    assert(seated <= emitter.depth);
    assert(emitter.depth <= brace.nest_depth_max);

    var at = seated;

    while (at < emitter.depth) : (at += 1) {
        const frame = emitter.nest[at];
        const unparenthesized = !frame.kind.eql(.{ .punctuation = .paren_open });
        const nested = unparenthesized or list.calling(emitter, frame.open);
        if (nested) return true;
    }

    return false;
}

pub fn paren_run(emitter: *const Emitter) bool {
    assert(emitter.depth <= brace.nest_depth_max);
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    if (emitter.wraps_owed == 0) return false;
    if (emitter.depth == 0) return false;

    const held = emitter.wrapped[wrap.run_top(emitter)];
    const frame = line.frame(emitter);
    const last = paren_run_last(emitter, frame.close);
    const started = emit.ahead_of(emitter, frame.open) == held.start;
    const commented = line.coding(emitter, frame.open) == held.start;
    const leads = started or commented;
    const parenthesized = held.wrap == .argued or held.wrap == .paired;
    if (!parenthesized) return false;
    if (held.depth != emitter.depth) return false;
    if (!frame.kind.eql(.{ .punctuation = .paren_open })) return false;
    if (!leads) return false;
    return last == held.close;
}

fn paren_run_last(emitter: *const Emitter, close: u32) ?u32 {
    assert(close < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const held = emit.back_of(emitter, close) orelse return null;
    if (!emitter.tokens[held].is_punctuation(.comma)) return held;
    return emit.back_of(emitter, held);
}

fn body_grouped(emitter: *const Emitter) bool {
    assert(emitter.depth <= brace.nest_depth_max);
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    if (emitter.wraps_owed == 0) return false;
    if (emitter.depth == 0) return false;

    const held = emitter.wrapped[wrap.run_top(emitter)];
    if (held.wrap != .bodied) return false;
    if (held.depth >= emitter.depth) return false;

    const frame = line.frame(emitter);
    if (!frame.kind.eql(.{ .punctuation = .paren_open })) return false;
    if (list.calling(emitter, frame.open)) return false;

    const before = emit.back_of(emitter, frame.open);
    const before_operator = before != null and wrapping_operator(emitter, before.?);
    const after = emit.ahead_of(emitter, frame.close);
    const after_operator = after != null and wrapping_operator(emitter, after.?);

    return before_operator or after_operator;
}

fn body_owned(emitter: *const Emitter, previous: u32) bool {
    assert(previous < emitter.count);
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    if (emitter.wraps_owed == 0) return false;

    const held = emitter.wrapped[wrap.run_top(emitter)];
    if (held.wrap != .bodied) return false;
    if (held.depth != emitter.depth) return false;
    if (held.floor == call.binary_level_max) return false;
    if (previous <= held.start) return false;
    if (previous > held.close) return false;
    return call.binary_level(emitter.tokens[previous].text(emitter.source)) == held.floor;
}

fn binary_spine(emitter: *const Emitter, head: u32, stop: u32, previous: u32) bool {
    assert(head <= stop);
    assert(stop < emitter.count);

    var ranks: [binary_operator_max]struct { u32, u32 } = @splat(.{ 0, 0 });
    const count = binary_ranked(emitter, head, stop, &ranks) orelse return false;
    var least: u32 = std.math.maxInt(u32);
    var rank_index: u32 = 0;

    while (rank_index < count) : (rank_index += 1) {
        if (ranks[rank_index][1] < least) least = ranks[rank_index][1];
    }

    var owned = false;
    var walk_index = count;

    while (walk_index > 0) {
        walk_index -= 1;

        const position = ranks[walk_index][0];
        const rank = ranks[walk_index][1];
        if (rank != least) continue;

        if (owned) {
            if (!binary_flattens(emitter, position)) return false;
        }

        if (position == previous) return true;

        owned = true;
    }

    return false;
}

pub fn binary_ranked(
    emitter: *const Emitter,
    head: u32,
    stop: u32,
    ranks: *[binary_operator_max]struct { u32, u32 },
) ?u32 {
    assert(head <= stop);
    assert(stop < emitter.count);

    var count: u32 = 0;
    var depth: u32 = 0;
    var scan = head;

    while (scan <= stop) {
        const skipped = tmpl.template_body(emitter, scan) orelse jsx_body(emitter, scan);

        if (skipped) |end| {
            scan = end + 1;

            continue;
        }

        const kind = emitter.tokens[scan].kind;

        if (walk.is_open(kind)) {
            depth += 1;
        } else if (walk.is_close(kind)) {
            depth -|= 1;
        } else if (depth == 0) {
            if (binary_rank(emitter, scan)) |rank| {
                if (count == binary_operator_max) return null;

                ranks[count] = .{ scan, rank };
                count += 1;
            }
        } else {}

        scan += 1;
    }

    if (count == 0) return null;
    return count;
}

fn binary_flattens(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const text = emitter.tokens[position].text(emitter.source);
    if (words_contain(binary_equalities, text)) return false;
    return !words_contain(binary_products, text);
}

fn branch_seat(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.ternary_parts) return false;

    const text = emitter.tokens[position].text(emitter.source);
    if (walk.text_is(text, "?")) return !tern.optional(emitter, position);
    if (walk.text_is(text, ":")) return tern.ternary(emitter, position);
    return false;
}

fn binary_seat(emitter: *const Emitter, head: u32, stop: u32) ?u32 {
    assert(head < emitter.count);
    assert(stop < emitter.count);

    const seat = emit.back_of(emitter, head) orelse return null;
    const token = emitter.tokens[seat];
    const text = token.text(emitter.source);

    const wrapped = token.is_punctuation(.assign) or words_contain(wrapped_words, text) or
        (emitter.policy.chain_simples and walk.text_is(text, "=>"));

    if (wrapped) return seat;
    if (branch_seat(emitter, seat)) return seat;

    const opened = token.is_punctuation(.comma) or token.is_punctuation(.paren_open) or
        token.is_punctuation(.bracket_open);

    const owns = list.spreads(emitter) or binary_grouped(emitter, seat);

    const seated = emitter.policy.chain_simples and owns and opened and
        line.frame(emitter).open <= seat;

    if (seated) return seat;
    if (!token.is_punctuation(.paren_open)) return null;

    const word = emit.back_of(emitter, seat) orelse return null;
    if (!words_contain(wrapped_words, emitter.tokens[word].text(emitter.source))) return null;

    const close = join.closing_of(emitter, seat) orelse return null;
    const after_stop = emit.ahead_of(emitter, stop);
    if (after_stop != close) return null;

    const after_close = emit.ahead_of(emitter, close);
    const trails = after_close == null or emitter.tokens[after_close.?].is_punctuation(.semicolon);
    if (trails) return seat;
    return null;
}

pub fn binary_inlined(emitter: *const Emitter, stop: u32) bool {
    assert(stop < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const kind = emitter.tokens[stop].kind;

    if (emit.roled(emitter, stop, brace.role_jsx)) return true;
    if (jsx.ended(emitter, stop)) return true;

    const closes = kind == .block_end or emitter.tokens[stop].is_punctuation(.bracket_close);
    if (!closes) return false;

    const open = emitter.brackets.open_of(stop) orelse return false;

    if (emit.word_before(emitter, open)) |held| {
        const token = emitter.tokens[held];

        const operand = token.ends_a_value() or emit.is_dot(emitter, held) or
            line.nonnull_ended(emitter, held);

        if (operand) return false;
    }

    const after = emit.ahead_of(emitter, open) orelse return false;
    return after != stop;
}

fn chain_wide(emitter: *const Emitter, head: u32, stop: u32, opening: bool) bool {
    assert(head <= stop);
    assert(stop < emitter.count);
    assert(emitter.policy.chain_simples);

    _ = opening;

    return chain_overflows(emitter, head, stop);
}

fn chain_overflows(emitter: *const Emitter, head: u32, chain_end: u32) bool {
    assert(head < emitter.count);
    assert(chain_end < emitter.count);

    const owned = link.chain_owned(emitter, head);
    const leader = link.chain_branch_head(emitter, head);
    const branch, const commented = chain_branch(emitter, leader);
    const seat = chain_overflows_seat(emitter, head, owned, leader, .{ branch, commented });
    if (seat[0] > head) return false;

    if (branch == null) {
        if (link.chain_ternary(emitter, head)) return false;
    }

    return chain_overflows_width(emitter, head, chain_end, seat, commented);
}

fn chain_overflows_seat(
    emitter: *const Emitter,
    head: u32,
    owned: bool,
    leader: u32,
    branched: struct { ?u32, bool },
) struct { u32, u32 } {
    assert((branched[0] orelse 0) < emitter.count);

    const branch, const commented = branched;

    assert(head < emitter.count);
    assert(leader < emitter.count);

    const arrowed = owned or chain_arrow_seated(emitter, head);

    if (arrowed) {
        const based = emitter.printed + link.seated_frames(emitter) +
            lead.spread_levels(emitter) + lead.chain_levels(emitter);

        return .{ link.chain_seated_at(emitter, head), based + @max(emitter.owed, 1) };
    }

    if (binary_seated(emitter, head)) {
        const based = @max(emitter.printed, wrap.seat_led_level(emitter));
        return .{ link.chain_seated_at(emitter, head), based + 1 + wrap.outer_runs(emitter, head) };
    }

    if (branch) |held| {
        return .{ if (commented) leader else held, tern.branch_chain_level(emitter, held) };
    }

    const from, const level = chain_line_seat(emitter, head);

    if (chain_key_parted(emitter, head, from, level)) |parted| {
        return .{ link.chain_seated_at(emitter, head), parted };
    }

    return .{ from, level };
}

fn chain_overflows_width(
    emitter: *const Emitter,
    head: u32,
    chain_end: u32,
    seat: struct { u32, u32 },
    commented: bool,
) bool {
    const from, const level = seat;

    assert(from <= head);
    assert(chain_end < emitter.count);

    const trailed = link.chain_trailed(emitter, head, chain_end) orelse chain_end;
    const stop = unite.chain_cast_stop(emitter, head, trailed) orelse trailed;
    const after = emit.ahead_of(emitter, stop);
    var end = stop;

    if (after) |held| {
        const kind = emitter.tokens[held].kind;
        const seated = wrapping_operator(emitter, held);

        const separated = kind.eql(.{ .punctuation = .comma }) or
            kind.eql(.{ .punctuation = .semicolon });

        const ending = seated or separated;

        if (ending) end = held;
    }

    const room = emitter.options.line_width;
    const headline = link.chain_headline(emitter, head, end);
    const reached = headline >= stop;
    const comma = reached and chain_arrow_seated(emitter, head) and link.arrow_argued(emitter);
    const listed = reached and link.chain_listed_last(emitter, head, stop);
    const aligned: u32 = if (commented) branch_align_columns else 0;

    const width = printed_columns(emitter, from, headline) +
        chain_head_widened(emitter, head, stop, headline) +
        @as(u32, @intFromBool(comma)) +
        @as(u32, @intFromBool(listed and !comma)) +
        link.chain_rest(emitter, headline, stop) +
        chain_comment_columns(emitter, stop) +
        aligned;

    return level * emitter.options.indent_width + width > room;
}

fn chain_comment_columns(emitter: *const Emitter, stop: u32) u32 {
    assert(stop < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var width: u32 = 0;
    var commented = false;

    for (stop + 1..emitter.count) |scan| {
        const token = emitter.tokens[scan];
        const text = token.text(emitter.source);

        if (token.length == 0) continue;
        if (token.kind == .newline) return 0;

        if (token.kind != .comment) {
            const separated = token.is_punctuation(.comma) or token.is_punctuation(.semicolon);
            assert(width + @intFromBool(commented and separated) < std.math.maxInt(u32));

            return width + @intFromBool(commented and separated);
        }

        if (std.mem.startsWith(u8, text, "//")) return width;
        if (std.mem.findScalar(u8, text, '\n') != null) return 0;

        width += 1 + walk.columns(emitter.source, token.offset, token.end());
        commented = true;
    }

    return width;
}

pub fn chain_valued(emitter: *const Emitter, head: u32) ?u32 {
    assert(head < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.chain_groups) return null;
    if (!emitter.policy.chain_simples) return null;

    const stop = link.chain_stop(emitter, head) orelse return null;
    var links: [chain_link_max]u32 = @splat(0);
    const count = link.chain_groups(emitter, head, stop, &links);
    const merges = chain_merges(emitter, head, &links, count);
    const cutoff: u32 = if (merges) 3 else 2;
    const from: usize = @intFromBool(merges);

    assert(count <= chain_link_max);

    if (count < cutoff) return null;
    if (chain_calls(emitter, head, stop) < 2) return null;
    if (call.chain_composed(emitter, head, stop)) return links[from];
    if (chain_overflows(emitter, head, stop)) return links[from];
    return null;
}

fn binary_armed(emitter: *const Emitter, held: u32) bool {
    assert(held < emitter.count);
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    if (emitter.wraps_owed == 0) return false;

    const top = wrap.run_top(emitter);
    const entry = emitter.wrapped[top];
    if (entry.wrap != .argued) return false;
    if (!emitter.wraps_armed[top]) return false;

    const head, const stop = binary_run(emitter, held) orelse return false;
    return head == entry.start and stop == entry.close;
}

pub fn binary_headless(emitter: *const Emitter, previous: u32) bool {
    assert(previous < emitter.count);

    const head, _ = binary_run(emitter, previous) orelse return false;
    const lead_found = join.line_lead(emitter, head);
    if (lead_found) |found| return found[0] != head;
    return true;
}

fn binary_headed_level(emitter: *const Emitter, previous: u32) ?u32 {
    assert(previous < emitter.count);

    const head, _ = binary_run(emitter, previous) orelse return null;
    const found = join.line_lead(emitter, head) orelse return null;

    return found[1];
}

fn binary_conditioned(emitter: *const Emitter, previous: u32) bool {
    assert(previous < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (!emitter.policy.header_parens) return false;
    if (emitter.depth == 0) return false;

    const frame = line.frame(emitter);
    if (!split.headed(emitter, frame.open)) return false;

    const head, const stop = binary_run(emitter, previous) orelse return false;
    const head_matches = emit.ahead_of(emitter, frame.open) == head;
    const stop_matches = emit.back_of(emitter, frame.close) == stop;

    return head_matches and stop_matches;
}

fn binary_parenthesized(emitter: *const Emitter, previous: u32) bool {
    assert(previous < emitter.count);

    const head, _ = binary_run(emitter, previous) orelse return false;
    const seat = emit.back_of(emitter, head) orelse return false;

    return !list.spreads(emitter) and binary_grouped(emitter, seat);
}

fn binary_grouped(emitter: *const Emitter, seat: u32) bool {
    assert(seat < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.depth == 0) return false;

    const frame = line.frame(emitter);
    if (frame.open != seat) return false;
    if (frame.bodied) return false;
    if (!emitter.tokens[seat].is_punctuation(.paren_open)) return false;
    if (list.calling(emitter, seat)) return false;
    return !split.headed(emitter, seat);
}

fn binary_based(emitter: *const Emitter, previous: u32) ?u32 {
    assert(previous < emitter.count);

    const head, _ = binary_run(emitter, previous) orelse return null;
    return element_level(emitter, head);
}

fn item_level(emitter: *const Emitter) u32 {
    assert(emitter.count == emitter.tokens.len);
    assert(emitter.printed <= core.line_level_max);

    return emitter.printed;
}

pub fn printer_level(emitter: *const Emitter) u32 {
    assert(emitter.printed <= core.line_level_max);
    assert(emitter.count == emitter.tokens.len);

    return emitter.printed + (emitter.broken -| emitter.broken_line);
}

pub fn binary_run(emitter: *const Emitter, position: u32) ?struct { u32, u32 } {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const head = binary_run_head(emitter, position) orelse return null;
    var stop = binary_run_stop(emitter, position) orelse return null;

    for (0..chain_scan_max) |_| {
        if (stop <= position) break;
        if (!emit.comment_ended(emitter, stop)) break;

        stop = emit.back_of(emitter, stop) orelse return null;
    }

    if (head >= position) return null;
    if (stop <= position) return null;
    return .{ head, stop };
}

fn binary_run_angled(emitter: *const Emitter, held: u32, position: u32) bool {
    assert(held < emitter.count);
    assert(position < emitter.count);

    return emitter.brackets.angles_at(held) > emitter.brackets.angles_at(position);
}

fn binary_run_head(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var head = position;

    for (0..chain_scan_max) |_| {
        const before = emit.back_of(emitter, head) orelse break;
        const token = emitter.tokens[before];
        const closes = walk.is_close(token.kind);

        if (binary_run_angled(emitter, before, position)) {
            if (!closes) {
                head = before;

                continue;
            }
        }

        if (closes) {
            head = emitter.brackets.open_of(before) orelse return null;

            continue;
        }

        if (walk.is_open(token.kind)) break;
        if (words_contain(binary_stops, token.text(emitter.source))) break;

        head = before;
    }

    return head;
}

fn binary_run_stop(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var stop = position;

    for (0..chain_scan_max) |_| {
        const after = emit.ahead_of(emitter, stop) orelse break;
        const skipped = tmpl.template_body(emitter, after) orelse jsx_body(emitter, after);

        if (skipped) |end| {
            stop = end;

            continue;
        }

        const token = emitter.tokens[after];

        if (walk.is_open(token.kind)) {
            stop = join.closing_of(emitter, after) orelse return null;

            continue;
        }

        if (walk.is_close(token.kind)) break;

        if (!binary_run_angled(emitter, after, position)) {
            if (words_contain(binary_stops, token.text(emitter.source))) break;
        }

        stop = after;
    }

    return stop;
}

fn binary_valued(emitter: *const Emitter, equals: u32) ?struct { u32, u32 } {
    assert(equals < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var depth: u32 = 0;
    var scan = emit.ahead_of(emitter, equals) orelse return null;

    for (0..chain_scan_max) |_| {
        const skipped = tmpl.template_body(emitter, scan) orelse jsx_body(emitter, scan);

        if (skipped) |end| {
            scan = emit.ahead_of(emitter, end) orelse return null;

            continue;
        }

        const token = emitter.tokens[scan];

        if (walk.is_open(token.kind)) {
            depth += 1;
        } else if (walk.is_close(token.kind)) {
            if (depth == 0) return null;

            depth -= 1;
        } else if (depth == 0) {
            if (words_contain(binary_stops, token.text(emitter.source))) return null;
            if (wrapping_operator(emitter, scan)) return binary_run(emitter, scan);
        } else {}

        scan = emit.ahead_of(emitter, scan) orelse return null;
    }

    return null;
}

pub fn property_head(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (!line.word_is(emitter, position, emitter.policy.parameter_words)) return false;

    const after = emit.ahead_of(emitter, position) orelse return false;
    const kind = emitter.tokens[after].kind;
    const named = kind == .identifier or kind == .keyword;
    if (!named) return false;

    var scan = position;

    for (0..argument_head_max) |_| {
        const before = emit.back_of(emitter, scan) orelse return true;
        const token = emitter.tokens[before];
        const listed = token.is_punctuation(.paren_open) or token.is_punctuation(.comma);
        if (listed) return true;

        const worded = line.word_is(emitter, before, emitter.policy.parameter_words);

        if (!worded) {
            if (!walk.text_is(token.text(emitter.source), "@")) return false;
        }

        scan = before;
    }

    return false;
}

fn binary_parted(emitter: *const Emitter, head: u32, stop: u32) bool {
    assert(head <= stop);
    assert(stop < emitter.count);

    var depth: u32 = 0;
    var previous = head;
    var scan = head;

    while (scan <= stop) {
        const skipped = tmpl.template_body(emitter, scan) orelse jsx_body(emitter, scan);

        if (skipped) |end| {
            assert(end >= scan);

            previous = end;
            scan = end + 1;

            continue;
        }

        const token = emitter.tokens[scan];
        const blank = token.kind == .newline or token.length == 0;

        if (blank) {
            scan += 1;

            continue;
        }

        const parting = depth == 0 and scan > head;

        if (parting) {
            const gap = body.parted_by(emitter, emitter.tokens[previous].end(), token.offset);

            if (gap > 0) {
                if (!operator_leads(emitter, scan)) return true;
            }
        }

        if (walk.is_open(token.kind)) {
            depth += 1;
        } else if (walk.is_close(token.kind)) {
            depth -|= 1;
        } else {}

        previous = scan;
        scan += 1;
    }

    return false;
}

fn run_trailing(emitter: *const Emitter, head: u32, stop: u32, seat: ?u32) u32 {
    assert(head <= stop);
    assert(stop < emitter.count);
    if (seat) |held| assert(held < emitter.count);

    const carried = seat != null;
    const after = emit.ahead_of(emitter, stop);
    var separated = false;

    if (after) |held| {
        const token = emitter.tokens[held];

        separated = token.is_punctuation(.comma) or token.is_punctuation(.semicolon);
    }

    const added = run_trailing_added(emitter, after);
    const trail = call.operand_trail(emitter, head, stop);

    if (separated) {
        if (trail > 0) return 1;
    }

    const owed: u32 = @intFromBool(carried and (separated or added));
    assert(owed + trail < std.math.maxInt(u32));

    return owed + trail;
}

fn run_trailing_added(emitter: *const Emitter, after: ?u32) bool {
    assert(emitter.depth <= brace.nest_depth_max);
    assert(emitter.count == emitter.tokens.len);

    if (!emitter.policy.comma_adds) return false;
    if (!list.spreads(emitter)) return false;
    if (after) |held| assert(held < emitter.count);

    const held = after orelse return false;

    assert(held < emitter.count);

    if (held != line.frame(emitter).close) return false;
    return !sole.comma_denied(emitter, held);
}

fn binary_inline(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    var depth = emitter.depth;
    const found = lead.spread(emitter, position);
    const leader = if (found) |held| held[0] else emitter.line_first;

    while (depth > 0) {
        const frame = emitter.nest[depth - 1];
        if (frame.kind == .block_start) return frame.open >= leader;

        depth -= 1;
    }

    return false;
}

fn wrapping_ternary(emitter: *const Emitter, head: u32) bool {
    assert(head < emitter.count);
    assert(emitter.wraps_owed <= core.wrap_depth_max);

    for (emitter.wrapped[0..emitter.wraps_owed]) |held| {
        const branchy = switch (held.wrap) {
            .guarded, .nested, .ternary => true,
            else => false,
        };

        if (!branchy) continue;
        if (head <= held.start) continue;
        if (head > held.close) continue;
        return true;
    }

    return false;
}

fn binary_argued(emitter: *const Emitter, previous: u32) bool {
    assert(previous < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    return binary_argued_run(emitter, previous, true);
}

pub fn binary_argued_run(emitter: *const Emitter, previous: u32, leading: bool) bool {
    assert(previous < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (!emitter.policy.chain_simples) return false;

    const head, const stop = binary_run(emitter, previous) orelse return false;

    if (leading) {
        if (emitter.line_before > head) {
            if (!sole.binary_rank_first(emitter, head, stop, previous)) return false;
        }
    }

    if (bind.sequence_wrapped_item(emitter, previous)) return true;
    if (!list.spreads(emitter)) return false;

    const frame = line.frame(emitter);
    if (split.headed(emitter, frame.open)) return false;
    if (list.paren_grouped(emitter, frame.open, frame.close)) return false;

    const seat = binary_seat(emitter, head, stop) orelse return false;
    return list.argued_seat(emitter, seat);
}

pub fn braced_columns(emitter: *const Emitter, from: u32, to: u32) u32 {
    assert(from <= emitter.count);
    assert(to <= emitter.count);

    return 0;
}

pub fn union_open(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (core.memo_found(emitter, .union_open, position, 0)) |answer| {
        return if (answer == core.memo_none) null else answer;
    }

    const open = union_open_scanned(emitter, position);

    core.memo_store(emitter, .union_open, position, 0, open orelse core.memo_none);

    return open;
}

fn union_open_scanned(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var angles: u32 = 0;
    var budget: u32 = union_bars_scan_max;
    var depth: u32 = 0;
    var scan = position;

    while (budget > 0) {
        budget -= 1;

        const held = emit.back_of(emitter, scan) orelse return null;
        const kind = emitter.tokens[held].kind;

        assert(held < scan);

        if (kind == .comment) {
            scan = held;

            continue;
        }

        if (bind.hole_open(emitter, held)) |open| {
            scan = open;

            continue;
        }

        const closes = walk.is_close(kind) or kind == .block_end;
        const opens = walk.is_open(kind) or kind == .block_start;

        if (closes) {
            if (union_skipped(emitter, held)) |open| {
                const steps = emitter.brackets.stepped(open, held);
                if (steps > budget) return null;

                budget -= steps;
                scan = open;

                continue;
            }

            depth += 1;
        } else if (opens) {
            if (depth == 0) return if (union_paren(emitter, held)) held else null;

            depth -= 1;
        } else if (depth == 0) {
            if (union_open_flat(emitter, held, &angles)) |found| return if (found) held else null;
        } else {}

        scan = held;
    }

    return null;
}

fn union_open_flat(emitter: *const Emitter, held: u32, angles: *u32) ?bool {
    assert(held < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const text = emitter.tokens[held].text(emitter.source);

    if (walk.text_is(text, ">")) {
        angles.* += 1;

        return null;
    }

    if (walk.text_is(text, "<")) {
        if (angles.* == 0) return unite.union_angled(emitter, held);

        angles.* -= 1;

        return null;
    }

    if (angles.* > 0) return null;
    return union_open_word(emitter, held);
}

fn union_open_word(emitter: *const Emitter, held: u32) ?bool {
    assert(held < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const token = emitter.tokens[held];
    const text = token.text(emitter.source);
    const assigns = token.is_punctuation(.assign) or token.is_punctuation(.colon);

    if (assigns) {
        if (token.is_punctuation(.colon)) {
            if (tern.ternary(emitter, held)) return false;
        }

        return !predicate_colon(emitter, held);
    }

    if (predicate_is(emitter, held)) return true;
    if (walk.text_is(text, "asserts")) return false;
    if (line.group_word(emitter, held)) return true;
    if (unite.union_arrow_type(emitter, held)) return true;
    if (unite.union_angle_item(emitter, held)) return true;
    if (walk.text_is(text, "extends")) return false;

    const separates = token.is_punctuation(.comma) or token.is_punctuation(.semicolon) or
        walk.text_is(text, "=>");

    if (separates) return false;
    return null;
}

pub fn predicate_is(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (emitter.policy.type_words.len == 0) return false;
    if (!walk.text_is(emitter.tokens[position].text(emitter.source), "is")) return false;

    const subject = emit.back_of(emitter, position) orelse return false;
    const token = emitter.tokens[subject];
    const named = token.kind == .identifier or walk.text_is(token.text(emitter.source), "this");
    if (!named) return false;

    const held = emit.back_of(emitter, subject) orelse return true;
    return !emit.is_dot(emitter, held);
}

pub fn union_wide(emitter: *const Emitter, held: *const Union) bool {
    assert(held.open < emitter.count);
    assert(held.head < emitter.count);

    const opens, const level = union_seat(emitter, held);
    const stop = unite.union_paren_stop(emitter, held);
    const reach = unite.paren_intersect_end(emitter, stop) orelse stop;
    const trailing = union_wide_trailing(emitter, held, stop);
    const angled = unite.union_listed(emitter, held.open);
    const led: u32 = if (held.lead == null) 0 else @as(u32, @intFromBool(!angled)) * bar_columns;

    const width = printed_columns(emitter, opens, reach) + union_columns(emitter, opens, reach) +
        trailing - led;

    const aligned = union_wide_aligned(emitter, held);
    const room = emitter.options.line_width -| (level * emitter.options.indent_width + aligned);

    if (angled) {
        if (unite.union_commented(emitter, held.head, stop)) return true;
        if (unite.union_brace_expanded(emitter, held.head, stop)) return true;
    } else {
        if (unite.union_expanded(emitter, held.head, stop)) return true;
    }

    if (width <= room) return false;
    if (unite.union_brace_fits(emitter, held)) return false;

    const enclosed = unite.union_enclosed(
        emitter,
        held,
        .{ opens, level },
        .{ stop, trailing + aligned, led },
    );

    if (enclosed) |judged| return judged;
    return union_wide_parted(emitter, held, .{ opens, stop, room, trailing, led });
}

fn union_wide_trailing(emitter: *const Emitter, held: *const Union, stop: u32) u32 {
    assert(stop < emitter.count);
    assert(held.open < emitter.count);

    const after = emit.ahead_of(emitter, stop) orelse return 0;
    const kind = emitter.tokens[after].kind;

    if (kind.eql(.{ .punctuation = .semicolon })) {
        const found = comment.separated(emitter, after) orelse return 1;
        const returned = 1 + (1 + printed_columns(emitter, found, found));

        assert(returned < std.math.maxInt(u32));

        return returned;
    }

    if (kind.eql(.{ .punctuation = .comma })) return 1;

    const closed = kind.eql(.{ .punctuation = .paren_close }) or
        kind.eql(.{ .punctuation = .bracket_close });

    if (closed) {
        if (union_listed_last(emitter, held.open, after)) return 1;
        return 0;
    }

    if (kind == .block_start) return 2;
    if (kind == .block_end) return union_wide_membered(emitter, held, after);

    if (kind.eql(.{ .punctuation = .assign })) {
        return unite.union_defaulted(emitter, held.open, after) orelse 2;
    }

    return 0;
}

fn union_wide_membered(emitter: *const Emitter, held: *const Union, close: u32) u32 {
    assert(held.open < emitter.count);
    assert(emitter.tokens[close].kind == .block_end);

    if (emitter.depth == 0) return 0;

    const frame = union_frame(emitter, held.open);
    if (frame.close != close) return 0;
    return @intFromBool(union_membered(emitter, &frame));
}

fn union_wide_aligned(emitter: *const Emitter, held: *const Union) u32 {
    assert(held.open < emitter.count);
    assert(emitter.depth <= brace.nest_depth_max);

    if (emitter.depth == 0) return 0;

    const frame = union_frame(emitter, held.open);
    if (!union_membered(emitter, &frame)) return 0;
    assert(emitter.union_stopped * bar_columns < std.math.maxInt(u32));

    return emitter.union_stopped * bar_columns;
}

fn union_wide_parted(
    emitter: *const Emitter,
    held: *const Union,
    measure: struct { u32, u32, u32, u32, u32 },
) bool {
    const opens, const stop, const room, const trailing, const led = measure;

    assert(opens < emitter.count);
    assert(stop < emitter.count);

    const anchor = union_anchor(emitter, held.open);
    if (union_wide_casted(emitter, held, anchor, opens, room)) return true;

    const paren = emit.back_of(emitter, anchor) orelse return true;
    if (!emitter.tokens[paren].kind.eql(.{ .punctuation = .paren_close })) return true;

    const open = emitter.brackets.open_of(paren) orelse return true;

    if (emit.ahead_of(emitter, open)) |inner| {
        if (inner == paren) return true;
    }

    return printed_columns(emitter, paren, stop) + union_columns(emitter, paren, stop) +
        trailing - led > room;
}

fn union_wide_casted(
    emitter: *const Emitter,
    held: *const Union,
    anchor: u32,
    opens: u32,
    room: u32,
) bool {
    assert(anchor < emitter.count);
    assert(held.open < emitter.count);

    if (emitter.tokens[anchor].kind.eql(.{ .punctuation = .colon })) return false;
    if (unite.union_arrow_type(emitter, held.open)) return false;
    assert(opens < std.math.maxInt(u32));

    return printed_columns(emitter, opens, held.open) <= room;
}

fn union_listed_last(emitter: *const Emitter, open: u32, close: u32) bool {
    assert(open < emitter.count);
    assert(close < emitter.count);

    const frame = union_frame(emitter, open);
    if (!union_itemed(frame.kind)) return false;
    if (frame.spread == null) return false;
    return frame.close == close;
}

pub fn union_anchor(emitter: *const Emitter, open: u32) u32 {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (predicate_returned(emitter, open)) {
        const colon = predicate_colon_of(emitter, open) orelse open;

        assert(colon <= open);

        return colon;
    }

    return open;
}

pub fn union_typed(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (core.memo_found(emitter, .union_typed, open, 0)) |answer| return answer == 1;

    const typed = union_typed_scanned(emitter, open);

    core.memo_store(emitter, .union_typed, open, 0, @intFromBool(typed));

    return typed;
}

fn union_typed_scanned(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    if (emitter.policy.type_words.len == 0) return false;
    if (emit.typing(emitter, union_head(emitter, open))) return true;
    if (tern.typed_frame(emitter)) return true;
    if (line.group_word(emitter, open)) return true;
    if (predicate_is(emitter, open)) return true;
    if (unite.union_arrow_type(emitter, open)) return true;
    if (union_paren(emitter, open)) return true;
    if (unite.union_listed(emitter, open)) return true;
    if (!emitter.tokens[open].kind.eql(.{ .punctuation = .colon })) return false;
    if (tern.ternary(emitter, open)) return false;
    return union_typed_colon(emitter, open);
}

fn union_typed_colon(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.tokens[open].kind.eql(.{ .punctuation = .colon }));

    if (emitter.depth > 0) {
        if (type_framed(emitter, union_frame(emitter, open).open)) return true;
    }

    if (unite.union_tuple_typed(emitter, open)) return true;

    if (emitter.depth > 0) {
        if (union_frame(emitter, open).kind.eql(.{ .punctuation = .paren_open })) return true;
    }

    const identified = union_typed_bound(emitter, open);
    const head = union_head(emitter, open);

    if (emitter.policy.binder_words.len > 0) {
        if (identified) {
            if (line.word_is(emitter, head, emitter.policy.binder_words)) return true;
        }
    }

    if (identified) {
        if (words_contain(field_words, emitter.tokens[head].text(emitter.source))) return true;
    }

    if (emitter.depth > 0) {
        const frame = union_frame(emitter, open);

        if (frame.kind == .block_start) {
            if (semi.classed_head(emitter, frame.open)) {
                if (identified) return true;
            }
        }
    }

    const held = emit.back_of(emitter, open) orelse return false;
    return emitter.tokens[held].kind.eql(.{ .punctuation = .paren_close });
}

fn union_typed_bound(emitter: *const Emitter, open: u32) bool {
    assert(open < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const held = unite.union_binder(emitter, open) orelse return false;
    return emitter.tokens[held].kind == .identifier;
}

pub fn binary_wide(emitter: *const Emitter, head: u32, last: u32) bool {
    assert(head < emitter.count);
    assert(last < emitter.count);

    const stop = bind.comment_stripped(emitter, head, last);
    if (link.header_fits(emitter, head, stop)) return false;

    const seat = binary_seat(emitter, head, stop);
    const operated = seat != null or call.binary_operated(emitter, head, stop);
    const opens = if (operated) head else binary_origin(emitter, head);
    if (stop <= opens) return false;

    const trailing = run_trailing(emitter, head, stop, seat);
    const spans, const leveled = binary_wide_spans(emitter, head, stop, opens, seat);

    const measured = lead.run_shadowed(emitter, spans) orelse
        binary_measured(emitter, spans, leveled, seat);

    const room = emitter.options.line_width;
    const width = printed_columns(emitter, spans, stop) + chain_widened(emitter, head, stop);

    if (sole.binary_soled(emitter, head, stop)) {
        const soles = binary_soles(emitter, spans, head, stop, measured, width, trailing);
        if (soles) |held| return held;
    }

    if (!emitter.policy.chain_simples) {
        if (!binary_fits(emitter, head, stop, measured)) return false;
    }

    const columns = measured * emitter.options.indent_width + width + trailing +
        tern.branch_run_columns(emitter, seat);

    return columns > room;
}

fn binary_wide_spans(
    emitter: *const Emitter,
    head: u32,
    stop: u32,
    opens: u32,
    seat: ?u32,
) struct { u32, u32 } {
    assert(opens < stop);
    assert(stop < emitter.count);
    assert(head < emitter.count);
    if (seat) |held| assert(held < emitter.count);

    const opened, const led = lead.spread(emitter, head) orelse
        .{ emitter.line_first, emitter.printed };

    const based = binary_seat_level(emitter, seat, led);
    const stepped = binary_wide_stepped(emitter, head, stop, seat, opened);
    const owed = binary_owed(emitter, based == led);
    const levels = based + owed + @as(u32, @intFromBool(stepped));
    var worded = false;

    if (seat) |found| {
        worded = words_contain(wrapped_words, emitter.tokens[found].text(emitter.source));
    }

    var sequenced: ?u32 = null;

    if (seat) |held| {
        if (bind.sequence_seated_run(emitter, held, head)) sequenced = held;
    }

    if (call.operand_seat(emitter, head, stop)) |seated| return seated;
    if (worded) return .{ seat.?, based + owed };
    if (sequenced) |open| return .{ open, based + owed };
    return .{ comment.spanned(emitter, opens, stop), levels };
}

fn binary_wide_stepped(
    emitter: *const Emitter,
    head: u32,
    stop: u32,
    seat: ?u32,
    opened: u32,
) bool {
    assert(head <= stop);
    assert(emitter.wraps_owed <= core.wrap_depth_max);
    if (seat) |held| assert(held < emitter.count);
    assert(opened < std.math.maxInt(u32));

    const held = emitter.wrapped[emitter.wraps_owed -| 1];
    const guarded = held.wrap == .guarded or held.wrap == .nested or held.wrap == .ternary;
    const tested = guarded and stop < held.floor;
    const owing = emitter.wraps_owed > 0 and head <= held.close;
    const lined = held.start < emitter.line_first;
    const wrapped = owing and held.wrap != .paired and !tested and !lined;

    return clause.run_stepped(emitter, wrapped, seat, opened, head);
}

fn binary_measured(emitter: *const Emitter, spans: u32, leveled: u32, seat: ?u32) u32 {
    assert(spans < emitter.count);
    assert(emitter.count == emitter.tokens.len);
    assert(leveled < std.math.maxInt(u32));
    if (seat) |held| assert(held < emitter.count);

    if (spans == emitter.line_first) return @max(leveled, link.led_level(emitter));

    const level = link.led_argued(emitter, seat) orelse return leveled;
    return @max(leveled, level);
}

fn binary_seat_level(emitter: *const Emitter, seat: ?u32, led: u32) u32 {
    assert(emitter.depth <= brace.nest_depth_max);

    if (seat) |held| assert(held < emitter.count);
    assert(led < std.math.maxInt(u32));

    var framed = false;

    if (seat) |held| framed = held == line.frame(emitter).open;

    const headed = emitter.depth > 0 and split.headed(emitter, line.frame(emitter).open) and
        framed;

    const inset = (list.spreads(emitter) or headed) and framed;
    const based = if (inset) @max(led, line.frame(emitter).inset + 1) else led;

    if (headed) {
        const printed = emitter.printed + spread_count(emitter) + wrap_levels(emitter);
        const returned = @max(based, printed);

        assert(returned < std.math.maxInt(u32));

        return returned;
    }

    assert(based < std.math.maxInt(u32));

    return based;
}

fn binary_soles(
    emitter: *const Emitter,
    opens: u32,
    head: u32,
    stop: u32,
    levels: u32,
    width: u32,
    trailing: u32,
) ?bool {
    assert(opens < emitter.count);
    assert(stop < emitter.count);
    assert(head < emitter.count);
    assert(levels < std.math.maxInt(u32));
    assert(width < std.math.maxInt(u32));
    assert(trailing < std.math.maxInt(u32));

    const operator = binary_last(emitter, head, stop) orelse return false;
    const from, const steps = binary_tail(emitter, opens, operator);

    if (binary_soles_led(emitter, from, operator)) {
        return binary_soles_lined(emitter, operator, stop, trailing);
    }

    const indent_width = emitter.options.indent_width;

    const before = printed_columns(emitter, from, operator) +
        chain_widened(emitter, from, operator);

    const room = emitter.options.line_width;
    const indent = (levels + steps) * indent_width;

    if (operand_expanded(emitter, from, operator)) |ended| {
        return levels * indent_width + printed_columns(emitter, ended, stop) + trailing > room;
    }

    if (indent + before + lead.ternary_align_columns(emitter) <= room) return null;

    if (operand_run_last(emitter, from, operator)) |held| {
        return (levels + 1) * indent_width + printed_columns(emitter, held, stop) + trailing > room;
    }

    if (operand_ended(emitter, from, operator)) |ended| {
        return levels * indent_width + printed_columns(emitter, ended, stop) + trailing > room;
    }

    if (unite.operand_membered(emitter, from, operator)) |dot| {
        const deeper = (levels + 1) * indent_width;
        return deeper + printed_columns(emitter, dot, stop) + trailing > room;
    }

    const solid = operand_solid(emitter, from, operator);
    return solid and levels * indent_width + width + trailing > room;
}

fn binary_soles_led(emitter: *const Emitter, from: u32, operator: u32) bool {
    assert(from < emitter.count);
    assert(operator < emitter.count);

    if (emitter.line_first <= from) return false;
    if (emitter.line_first >= operator) return false;
    return unnested(emitter, emitter.line_first, operator);
}

fn binary_soles_lined(emitter: *const Emitter, operator: u32, stop: u32, trailing: u32) bool {
    assert(emitter.line_first < operator);
    assert(stop < emitter.count);
    assert(trailing < std.math.maxInt(u32));

    const led = link.led_level(emitter) * emitter.options.indent_width;
    const room = emitter.options.line_width;

    const operand = printed_columns(emitter, emitter.line_first, operator) +
        chain_widened(emitter, emitter.line_first, operator);

    if (led + operand <= room) {
        const rest = printed_columns(emitter, emitter.line_first, stop) +
            chain_widened(emitter, emitter.line_first, stop);

        return led + rest + trailing > room;
    }

    const ended = operand_ended(emitter, emitter.line_first, operator) orelse return true;
    return led + printed_columns(emitter, ended, stop) + trailing > room;
}

fn binary_fits(emitter: *const Emitter, head: u32, stop: u32, levels: u32) bool {
    assert(head <= stop);
    assert(stop < emitter.count);
    assert(levels < std.math.maxInt(u32));

    var ranks: [binary_operator_max]struct { u32, u32 } = @splat(.{ 0, 0 });
    const count = binary_ranked(emitter, head, stop, &ranks) orelse return false;
    var least: u32 = std.math.maxInt(u32);

    for (ranks[0..count]) |held| least = @min(least, held[1]);

    const indent = levels * emitter.options.indent_width;
    const room = emitter.options.line_width;
    var from = head;

    for (ranks[0..count]) |held| {
        const operator, const rank = held;

        if (rank != least) continue;

        if (from < operator) {
            if (indent + printed_columns(emitter, from, operator) > room) return false;
        }

        from = emit.ahead_of(emitter, operator) orelse return false;
    }

    if (from > stop) return true;
    return indent + printed_columns(emitter, from, stop) <= room;
}

pub fn binary_last(emitter: *const Emitter, head: u32, stop: u32) ?u32 {
    assert(head < emitter.count);
    assert(stop < emitter.count);

    var ranks: [binary_operator_max]struct { u32, u32 } = @splat(.{ 0, 0 });
    const count = binary_ranked(emitter, head, stop, &ranks) orelse return null;

    assert(count > 0);

    const root, const rank = ranks[0];
    var rooted = true;

    for (ranks[1..count]) |held| {
        if (held[1] <= rank) rooted = false;
    }

    if (rooted) return root;

    var least: u32 = std.math.maxInt(u32);

    for (ranks[0..count]) |held| least = @min(least, held[1]);

    var loosest: ?u32 = null;
    var loosest_count: u32 = 0;

    for (ranks[0..count]) |held| {
        if (held[1] != least) continue;

        if (loosest == null) loosest = held[0];

        loosest_count += 1;
    }

    if (loosest_count == 1) return loosest;
    assert(ranks[count - 1][0] < std.math.maxInt(u32));

    return ranks[count - 1][0];
}

fn binary_lined(emitter: *const Emitter, head: u32, stop: u32) bool {
    assert(head < emitter.count);
    assert(stop < emitter.count);

    const opens = binary_origin(emitter, head);
    if (stop <= opens) return false;

    const width = printed_columns(emitter, opens, stop) + chain_widened(emitter, head, stop);

    if (!binary_fits(emitter, head, stop, emitter.printed + 1)) return false;

    const indent = emitter.printed * emitter.options.indent_width;
    return indent + width + 1 > emitter.options.line_width;
}

fn operand_solid(emitter: *const Emitter, from: u32, operator: u32) bool {
    assert(from < emitter.count);
    assert(operator < emitter.count);

    var scan = from;

    while (scan < operator) : (scan += 1) {
        const kind = emitter.tokens[scan].kind;
        const opens = walk.is_open(kind) or kind == .block_start;

        if (opens) {
            const close = join.closing_of(emitter, scan) orelse return false;
            if (emit.ahead_of(emitter, scan) != close) return false;
        }
    }

    return true;
}

fn operand_expanded(emitter: *const Emitter, from: u32, operator: u32) ?u32 {
    assert(from < emitter.count);
    assert(operator < emitter.count);

    const ended = operand_ended(emitter, from, operator) orelse return null;
    const last = emit.back_of(emitter, ended) orelse return null;
    if (emitter.tokens[last].kind != .block_end) return null;

    const open = emitter.brackets.open_of(last) orelse return null;
    const first = emit.ahead_of(emitter, open) orelse return null;
    if (first >= last) return null;
    if (!body.parts_at(emitter, open, first)) return null;
    return ended;
}

fn operand_ended(emitter: *const Emitter, from: u32, operator: u32) ?u32 {
    assert(from < emitter.count);
    assert(operator < emitter.count);

    var end = emit.back_of(emitter, operator) orelse return null;
    if (end <= from) return null;

    while (emitter.tokens[end].kind == .comment) {
        const before = emit.back_of(emitter, end) orelse return null;

        assert(before < end);

        if (before <= from) return null;

        end = before;
    }

    if (!walk.is_close(emitter.tokens[end].kind)) return null;

    const open = emitter.brackets.open_of(end) orelse return null;
    if (open < from) return null;
    if (emit.ahead_of(emitter, open) == end) return null;
    return end;
}

fn unnested(emitter: *const Emitter, from: u32, to: u32) bool {
    assert(from < to);
    assert(to < emitter.count);

    var depth: u32 = 0;
    var scan = from;

    while (scan < to) {
        const skipped = tmpl.template_body(emitter, scan) orelse jsx_body(emitter, scan);

        if (skipped) |end| {
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
            if (depth == 0) return false;

            depth -= 1;
        } else {}

        scan += 1;
    }

    return true;
}

fn operand_run_last(emitter: *const Emitter, from: u32, operator: u32) ?u32 {
    assert(from < emitter.count);
    assert(operator < emitter.count);

    const end = emit.back_of(emitter, operator) orelse return null;
    if (end <= from) return null;

    var ranks: [binary_operator_max]struct { u32, u32 } = @splat(.{ 0, 0 });
    const count = binary_ranked(emitter, from, end, &ranks) orelse return null;
    var least: u32 = std.math.maxInt(u32);

    for (ranks[0..count]) |held| least = @min(least, held[1]);

    var index = count;
    var tightest: ?u32 = null;

    while (index > 0) {
        index -= 1;

        if (ranks[index][1] == least) {
            tightest = ranks[index][0];

            break;
        }
    }

    const held = tightest orelse return null;
    const after = emit.ahead_of(emitter, held) orelse return null;
    if (after > end) return null;
    return after;
}

fn binary_tail(emitter: *const Emitter, opens: u32, operator: u32) struct { u32, u32 } {
    assert(opens < emitter.count);
    assert(operator < emitter.count);

    const held: struct { u32, u32 } = .{ opens, 0 };
    const end = emit.back_of(emitter, operator) orelse return held;
    if (end <= opens) return held;
    if (!emitter.tokens[opens].is_punctuation(.paren_open)) return held;
    if (join.closing_of(emitter, opens) != end) return held;

    const value = binary_assigned_value(emitter, opens, end) orelse return held;
    if (own.tail_called(emitter, value, end)) return held;
    return .{ value, 1 };
}

fn binary_assigned_value(emitter: *const Emitter, opens: u32, close: u32) ?u32 {
    assert(opens < close);
    assert(close < emitter.count);

    var depth: u32 = 0;
    var scan = opens + 1;

    while (scan < close) : (scan += 1) {
        const token = emitter.tokens[scan];
        const opened = walk.is_open(token.kind) or token.kind == .block_start;
        const closes = walk.is_close(token.kind) or token.kind == .block_end;

        if (opened) {
            depth += 1;
        } else if (closes) {
            depth -|= 1;
        } else if (depth == 0) {
            if (binary_assigned_equals(emitter, scan)) return emit.ahead_of(emitter, scan);
        } else {}
    }

    return null;
}

fn binary_assigned_equals(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const token = emitter.tokens[position];
    if (!token.is_punctuation(.assign)) return false;
    return walk.text_is(token.text(emitter.source), "=");
}

fn binary_origin(emitter: *const Emitter, head: u32) u32 {
    assert(head < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    var opens = head;

    for (0..chain_scan_max) |_| {
        const before = emit.back_of(emitter, opens) orelse break;
        const token = emitter.tokens[before];

        if (walk.is_close(token.kind)) {
            if (token.kind != .block_end) {
                if (edge.header_closed(emitter, before, opens)) break;

                opens = emitter.brackets.open_of(before) orelse break;

                continue;
            }
        }

        if (binary_origin_stops(emitter, before)) break;

        opens = before;
    }

    assert(opens <= head);

    return opens;
}

fn binary_origin_stops(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.count);
    assert(emitter.count == emitter.tokens.len);

    const token = emitter.tokens[position];
    if (walk.is_open(token.kind)) return true;
    if (walk.is_close(token.kind)) return true;
    if (token.kind == .comment) return true;
    if (token.is_punctuation(.colon)) return true;
    if (token.is_punctuation(.comma)) return true;
    return token.is_punctuation(.semicolon);
}
