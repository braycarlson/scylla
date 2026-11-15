const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../stdx/bounded/array.zig").ArrayType;
const Buffer = @import("../stdx/bounded/buffer.zig");
const EventsType = @import("../syntax/tree.zig").EventsType;
const Formatter = @import("javascript.zig").Formatter;
const FormatterError = @import("formatters.zig").FormatterError;
const Input = @import("javascript.zig").Input;
const Kind = @import("../syntax/javascript/kind.zig").Kind;
const Language = @import("../syntax/language.zig").Language;
const Options = @import("print.zig").Options;
const Parser = @import("../syntax/javascript/parse.zig").Parser;
const Span = @import("../stdx/bounded/span.zig");
const Structure = @import("../syntax/tree.zig").Structure;
const Token = @import("../syntax/token.zig");
const Tokens = @import("../syntax/tokens.zig");
const TreeType = @import("../syntax/tree.zig").TreeType;
const bodied = @import("text.zig").bodied;
const corpus = @import("../testing/corpus.zig");
const environment = @import("../testing/environment.zig");
const floor = @import("../testing/floor.zig");
const keyed_name = @import("text.zig").named_key;
const lex = @import("../syntax/lex.zig").lex;
const numbered_key = @import("text.zig").numbered_key;
const oracle = @import("../testing/oracle.zig");
const raw_of = @import("../syntax/raw.zig").raw_of;
const renumbered = @import("text.zig").renumbered;
const stripe = @import("../testing/stripe.zig");
const unicode = @import("../text/unicode.zig");
const walk = @import("walk.zig");
const Events = EventsType(Kind);
const Tree = TreeType(Kind);

const Held = struct {
    events: *Events,
    formatter: Formatter,
    parser: *Parser,
    raw: ArrayType(Kind),
    tokens: Tokens,
    tree: Tree,

    fn init(held: *Held, gpa: std.mem.Allocator) !void {
        held.events = try gpa.create(Events);
        errdefer gpa.destroy(held.events);

        try held.events.init(gpa, event_count_max);
        errdefer held.events.deinit(gpa);

        held.formatter = try .init(gpa, element_count_max, out_bytes_max);
        errdefer held.formatter.deinit(gpa);

        held.parser = try gpa.create(Parser);
        errdefer gpa.destroy(held.parser);

        held.raw = try .init(gpa, token_count_max);
        errdefer held.raw.deinit(gpa);

        held.tokens = try .init(gpa, token_count_max);
        errdefer held.tokens.deinit(gpa);

        held.tree = try .init(gpa, node_count_max, diagnostic_count_max);

        assert(held.raw.capacity() == held.tokens.items.capacity());
        assert(held.tree.count() == 0);
    }

    fn deinit(held: *Held, gpa: std.mem.Allocator) void {
        assert(held.raw.capacity() == token_count_max);
        assert(held.tokens.items.capacity() == token_count_max);

        held.tree.deinit(gpa);
        held.tokens.deinit(gpa);
        held.raw.deinit(gpa);
        gpa.destroy(held.parser);
        held.formatter.deinit(gpa);
        held.events.deinit(gpa);
        gpa.destroy(held.events);
        held.* = undefined;
    }

    fn classified(held: *Held, source: []const u8) void {
        assert(source.len <= std.math.maxInt(u32));

        held.tokens.clear();

        lex(.of(.javascript), source, &held.tokens) catch |err| switch (err) {
            error.Truncated => assert(held.tokens.items.full()),
        };

        raw_of(Kind, held.tokens.slice(), &held.raw) catch unreachable;

        assert(held.raw.count() == held.tokens.count());
        assert(held.raw.count() <= token_count_max);
    }

    fn comments(held: *Held, arena: std.mem.Allocator, source: []const u8) ![]const []const u8 {
        assert(source.len <= std.math.maxInt(u32));

        held.classified(source);

        const raw = held.raw.const_slice();
        const tokens = held.tokens.slice();

        assert(raw.len == tokens.len);

        var collected: std.ArrayList([]const u8) = try .initCapacity(arena, raw.len);

        for (raw, tokens) |kind, token| {
            if (kind != .comment) continue;

            collected.appendAssumeCapacity(
                std.mem.trimEnd(u8, token.text(source), ascii_whitespace),
            );
        }

        assert(collected.items.len <= raw.len);

        return collected.items;
    }

    fn format(held: *Held, source: []const u8, out: *Buffer) FormatterError!void {
        assert(source.len <= std.math.maxInt(u32));

        held.classified(source);

        const outcome = held.parsed(source);
        const input = held.input_of(source, outcome);

        assert(input.tokens.len == input.raw.len);
        assert(input.source.ptr == source.ptr);

        return held.formatter.format(&input, out);
    }

    fn input_of(held: *const Held, source: []const u8, outcome: Structure) Input {
        assert(held.raw.count() == held.tokens.count());
        assert(source.len <= std.math.maxInt(u32));
        if (outcome == .complete) assert(held.tree.count() > 0);

        return .{
            .options = Options.default,
            .outcome = outcome,
            .raw = held.raw.const_slice(),
            .source = source,
            .tokens = held.tokens.slice(),
            .tree = &held.tree,
        };
    }

    fn kinds(held: *Held, arena: std.mem.Allocator, source: []const u8) ![]const Kind {
        assert(source.len <= std.math.maxInt(u32));

        held.classified(source);

        const raw = held.raw.const_slice();
        const tokens = held.tokens.slice();

        assert(raw.len == tokens.len);

        var pairs: std.ArrayList(Pair) = try .initCapacity(arena, raw.len);

        for (raw, tokens) |kind, token| {
            if (kinds_skipped(kind)) continue;

            pairs.appendAssumeCapacity(.{ .kind = kind, .token = token });
        }

        assert(pairs.items.len <= raw.len);

        const spaced = try jsx_spaced(arena, source, pairs.items);

        assert(spaced.len <= pairs.items.len);

        return keyed(arena, source, spaced);
    }

    fn parsed(held: *Held, source: []const u8) Structure {
        const tokens = held.tokens.slice();
        const raw = held.raw.const_slice();

        assert(tokens.len == raw.len);
        assert(source.len <= std.math.maxInt(u32));

        return held.parser.build(
            source,
            tokens,
            raw,
            held.events,
            &held.tree,
            .{ .dialect = .javascript, .goal = .module },
        );
    }

    fn range(
        held: *Held,
        source: []const u8,
        lines: walk.LineRange,
        out: *Buffer,
    ) FormatterError!Span {
        assert(lines.first <= lines.last);
        assert(source.len <= std.math.maxInt(u32));

        held.classified(source);

        const outcome = held.parsed(source);
        const input = held.input_of(source, outcome);

        assert(input.tokens.len == input.raw.len);

        return held.formatter.range(&input, lines, out);
    }

    fn templates(held: *Held, arena: std.mem.Allocator, source: []const u8) ![]const []const u8 {
        assert(source.len <= std.math.maxInt(u32));

        held.classified(source);

        const raw = held.raw.const_slice();
        const tokens = held.tokens.slice();

        assert(raw.len == tokens.len);

        var collected: std.ArrayList([]const u8) = try .initCapacity(arena, raw.len);

        for (raw, tokens) |kind, token| {
            if (kind != .template_chars) continue;

            collected.appendAssumeCapacity(token.text(source));
        }

        assert(collected.items.len <= raw.len);

        return collected.items;
    }

    fn words(held: *Held, arena: std.mem.Allocator, source: []const u8) ![]const []const u8 {
        assert(source.len <= std.math.maxInt(u32));

        held.classified(source);

        const tokens = held.tokens.slice();
        var spelled: std.ArrayList(Token) = try .initCapacity(arena, tokens.len);

        for (tokens) |token| {
            if (word_skipped(token)) continue;

            spelled.appendAssumeCapacity(token);
        }

        var written: std.ArrayList([]const u8) = try .initCapacity(arena, spelled.items.len);

        for (0..spelled.items.len) |index| {
            const word = try word_written(arena, source, spelled.items, index);

            written.appendAssumeCapacity(word);
        }

        assert(written.items.len == spelled.items.len);
        assert(written.items.len <= tokens.len);

        return written.items;
    }
};

const Twice = struct {
    first: Buffer,
    held: Held,
    second: Buffer,

    fn init(twice: *Twice, gpa: std.mem.Allocator) !void {
        twice.first = try .init(gpa, out_bytes_max);
        errdefer twice.first.deinit(gpa);

        try twice.held.init(gpa);
        errdefer twice.held.deinit(gpa);

        twice.second = try .init(gpa, out_bytes_max);

        assert(twice.first.empty());
        assert(twice.second.empty());
    }

    fn deinit(twice: *Twice, gpa: std.mem.Allocator) void {
        assert(twice.first.capacity() == out_bytes_max);
        assert(twice.second.capacity() == out_bytes_max);

        twice.second.deinit(gpa);
        twice.held.deinit(gpa);
        twice.first.deinit(gpa);
        twice.* = undefined;
    }
};

const RelationsWorker = struct {
    arena: std.heap.ArenaAllocator,
    residue: *const oracle.Residue,
    twice: Twice,

    pub const Item = Fixture;
    pub const Shared = struct { residue: *const oracle.Residue };
    pub const Tally = struct { settling: u32 };
    pub const weight = Fixture.weight;

    pub fn init(worker: *RelationsWorker, gpa: std.mem.Allocator, shared: *const Shared) !void {
        assert(shared.residue.fixtures.items.len <= file_count_max);

        worker.arena = .init(gpa);
        errdefer worker.arena.deinit();

        try worker.twice.init(gpa);

        worker.residue = shared.residue;

        assert(worker.twice.first.empty());
    }

    pub fn deinit(worker: *RelationsWorker, gpa: std.mem.Allocator) void {
        assert(worker.twice.first.capacity() == out_bytes_max);

        worker.twice.deinit(gpa);
        worker.arena.deinit();
        worker.* = undefined;
    }

    pub fn visit(worker: *RelationsWorker, fixture: *const Fixture, tally: *Tally) !void {
        assert(fixture.name.len > 0);
        assert(tally.settling <= file_count_max);

        const twice = &worker.twice;

        twice.held.format(fixture.source, &twice.first) catch return;

        _ = worker.arena.reset(.retain_capacity);

        const allocator = worker.arena.allocator();
        const once = twice.first.const_slice();

        try relations_hold(&twice.held, allocator, fixture.*, once);

        const settled = try settles(&twice.held, once, &twice.second, fixture.name, worker.residue);

        if (settled) tally.settling += 1;
    }
};

const Divergence = struct {
    held: usize,
    at: usize,
};

const Edge = enum {
    leading,
    trailing,
};

const Fixture = corpus.File;

const JsxFrame = enum {
    children,
    closing,
    hole,
    tag,
};

const JsxSpace = struct {
    meaningful: bool,
    width: usize,
};

const Pair = struct {
    kind: Kind,
    token: Token,
};

const kind_side = struct {
    const Item = Kind;

    fn assigning(item: Kind) bool {
        if (!item.is_token()) return false;

        for (assigning_kinds) |kind| {
            if (kind == item) return true;
        }

        return false;
    }

    fn calls(held: []const Kind, open: usize) bool {
        assert(open < held.len);
        assert(held[open] == .paren_open);

        if (open == 0) return false;

        return switch (held[open - 1]) {
            .bracket_close,
            .identifier,
            .paren_close,
            .property_identifier,
            .super_keyword,
            .this_keyword,
            => true,
            else => false,
        };
    }

    fn closes(item: Kind) bool {
        if (!item.is_token()) return false;

        return item == .paren_close;
    }

    fn commented(item: Kind) bool {
        if (!item.is_token()) return false;

        return item == .comment;
    }

    fn eql(left: Kind, right: Kind) bool {
        assert(left.is_token());
        assert(right.is_token());

        return left == right;
    }

    fn ends_wrap(item: Kind) bool {
        if (!item.is_token()) return false;

        return item == .semicolon or item == .brace_close;
    }

    fn nests(item: Kind) i32 {
        assert(item.is_token());

        return switch (item) {
            .brace_open, .bracket_open, .paren_open => 1,
            .brace_close, .bracket_close, .paren_close => -1,
            else => 0,
        };
    }

    fn opens(item: Kind) bool {
        if (!item.is_token()) return false;

        return item == .paren_open;
    }

    fn semicolon(item: Kind) bool {
        if (!item.is_token()) return false;

        return item == .semicolon;
    }

    fn separates(item: Kind) bool {
        if (!item.is_token()) return false;

        return item == .comma;
    }

    fn shuts(item: Kind) bool {
        if (!item.is_token()) return false;

        return item == .brace_close or item == .bracket_close or item == .paren_close;
    }

    fn voids(item: Kind) bool {
        if (!item.is_token()) return false;

        const braced = item == .brace_open or item == .brace_close;
        return braced or item == .colon or item == .semicolon;
    }

    fn wraps(item: Kind) bool {
        if (!item.is_token()) return false;

        return item == .return_keyword or item == .throw_keyword;
    }
};

const word_side = struct {
    const Item = []const u8;

    fn assigning(item: []const u8) bool {
        assert(item.len <= std.math.maxInt(u32));

        for (assigning_words) |word| {
            if (std.mem.eql(u8, word, item)) return true;
        }

        return false;
    }

    fn calls(held: []const []const u8, open: usize) bool {
        assert(open < held.len);
        assert(std.mem.eql(u8, held[open], "("));

        if (open == 0) return false;

        const word = held[open - 1];
        if (word_in(word, &.{ "]", ")", "super", "this" })) return true;
        if (word.len == 0) return false;
        if (!word_opens_name(word)) return false;
        return !word_in(word, &calls_excluded_words);
    }

    fn closes(item: []const u8) bool {
        assert(item.len <= std.math.maxInt(u32));

        return std.mem.eql(u8, item, ")");
    }

    fn commented(item: []const u8) bool {
        assert(item.len <= std.math.maxInt(u32));

        return std.mem.startsWith(u8, item, "//") or std.mem.startsWith(u8, item, "/*");
    }

    fn eql(left: []const u8, right: []const u8) bool {
        assert(left.len <= std.math.maxInt(u32));
        assert(right.len <= std.math.maxInt(u32));

        return std.mem.eql(u8, left, right);
    }

    fn ends_wrap(item: []const u8) bool {
        assert(item.len <= std.math.maxInt(u32));

        return word_in(item, &.{ ";", "}" });
    }

    fn nests(item: []const u8) i32 {
        assert(item.len <= std.math.maxInt(u32));

        if (word_in(item, &.{ "{", "[", "(" })) return 1;
        if (word_in(item, &.{ "}", "]", ")" })) return -1;
        return 0;
    }

    fn opens(item: []const u8) bool {
        assert(item.len <= std.math.maxInt(u32));

        return std.mem.eql(u8, item, "(");
    }

    fn semicolon(item: []const u8) bool {
        assert(item.len <= std.math.maxInt(u32));

        return std.mem.eql(u8, item, ";");
    }

    fn separates(item: []const u8) bool {
        assert(item.len <= std.math.maxInt(u32));

        return std.mem.eql(u8, item, ",");
    }

    fn shuts(item: []const u8) bool {
        assert(item.len <= std.math.maxInt(u32));

        return word_in(item, &.{ ")", "]", "}" });
    }

    fn voids(item: []const u8) bool {
        assert(item.len <= std.math.maxInt(u32));

        return word_in(item, &.{ "{", "}", ":", ";" });
    }

    fn wraps(item: []const u8) bool {
        assert(item.len <= std.math.maxInt(u32));

        return word_in(item, &.{ "return", "throw" });
    }
};

const ascii_whitespace = " \t\n\x0c\r";

const assigning_kinds = [_]Kind{
    .ampersand_ampersand,
    .ampersand_ampersand_equal,
    .ampersand_equal,
    .bar_bar,
    .bar_bar_equal,
    .bar_equal,
    .caret_equal,
    .equal,
    .greater_greater_equal,
    .greater_greater_greater_equal,
    .less_less_equal,
    .minus_equal,
    .percent_equal,
    .plus_equal,
    .question_question,
    .question_question_equal,
    .slash_equal,
    .star_equal,
    .star_star_equal,
};

const assigning_words = [_][]const u8{
    "%=",
    "&&",
    "&&=",
    "&=",
    "**=",
    "*=",
    "+=",
    "-=",
    "/=",
    "<<=",
    "=",
    ">>=",
    ">>>=",
    "??",
    "??=",
    "^=",
    "|=",
    "||",
    "||=",
};

const calls_excluded_words = [_][]const u8{
    "case",
    "catch",
    "do",
    "else",
    "for",
    "if",
    "in",
    "instanceof",
    "of",
    "return",
    "switch",
    "throw",
    "typeof",
    "void",
    "while",
    "with",
    "yield",
};

const dump_variable = "SCYLLA_FORMAT_DUMP";
const element_count_max: u32 = 1 << 18;
const diagnostic_count_max: u32 = 1 << 12;
const event_count_max: u32 = 1 << 20;

const every_category = [_][]const u8{
    "biome-jsx-forced-break",
    "biome-jsx-layout",
    "biome-line-breaking",
    "biome-literal-normalisation",
    "biome-template-literals",
};

const every_unsettled = [_][]const u8{ "reference-unstable", "scylla-unstable" };
const extension = ".js";
const file_count_max: u32 = 1 << 20;
const fixture_count_min: u32 = 4;
const fixture_root = "tests/fixtures/javascript";
const golden_root = "tests/fixtures/golden-biome-javascript";
const jsx_blanks = " \t\n\r";
const jsx_fixture_count: u32 = 7;
const node_count_max: u32 = 1 << 18;
const number_bytes_max: u32 = 1 << 8;
const out_bytes_max: u32 = 1 << 22;
const paren_pass_max: u32 = 32;
const path_bytes_max: u32 = 4096;
const residue_format_name = "residue-format-javascript.json";
const residue_relations_name = "residue-relations-javascript.json";
const skipped_names = [_][]const u8{ "dedent", "indent", "newline" };
const source_bytes_max: u32 = 1 << 28;
const token_count_max: u32 = 1 << 18;

const unicode_spaces = [_][]const u8{
    "\u{85}",
    "\u{a0}",
    "\u{1680}",
    "\u{2000}",
    "\u{2001}",
    "\u{2002}",
    "\u{2003}",
    "\u{2004}",
    "\u{2005}",
    "\u{2006}",
    "\u{2007}",
    "\u{2008}",
    "\u{2009}",
    "\u{200a}",
    "\u{2028}",
    "\u{2029}",
    "\u{202f}",
    "\u{205f}",
    "\u{3000}",
};

const window_width: usize = 10;

fn assigned(
    comptime side: type,
    arena: std.mem.Allocator,
    held: []const side.Item,
) ![]const side.Item {
    assert(held.len <= std.math.maxInt(u32));

    var current = held;

    for (0..paren_pass_max) |_| {
        const found = try unassigned(side, arena, current);

        assert(found.len <= current.len);

        if (found.len == current.len) return found;

        current = found;
    }

    assert(current.len <= held.len);

    return current;
}

fn assigns(comptime side: type, held: []const side.Item, open: usize, close: usize) bool {
    assert(open < close);
    assert(close < held.len);

    var depth: u32 = 0;

    for (held[open + 1 .. close]) |item| {
        const nested = side.nests(item);

        if (nested > 0) {
            depth += 1;
        } else if (nested < 0) {
            depth -|= 1;
        } else if (depth == 0) {
            if (side.assigning(item)) return true;
        } else {}
    }

    return false;
}

fn bare_key(text: []const u8) ?[]const u8 {
    assert(text.len <= std.math.maxInt(u32));

    return named_key(text) orelse bare_name(text);
}

fn bare_name(text: []const u8) ?[]const u8 {
    if (!keyed_name(text)) return null;
    return text;
}

fn bracketed(arena: std.mem.Allocator, words: []const []const u8) ![]const []const u8 {
    assert(words.len <= std.math.maxInt(u32));

    var held: std.ArrayList([]const u8) = try .initCapacity(arena, words.len);
    var index: usize = 0;

    while (index < words.len) {
        if (index + 3 < words.len) {
            const lone = std.mem.eql(u8, words[index], "(") and
                std.mem.eql(u8, words[index + 2], ")") and
                std.mem.eql(u8, words[index + 3], "=>");

            if (lone) {
                held.appendAssumeCapacity(words[index + 1]);
                index += 3;

                continue;
            }
        }

        held.appendAssumeCapacity(words[index]);
        index += 1;
    }

    assert(held.items.len <= words.len);

    return held.items;
}

fn called(arena: std.mem.Allocator, kinds: []const Kind) ![]const Kind {
    assert(kinds.len <= std.math.maxInt(u32));

    var depth: u32 = 0;
    var held: std.ArrayList(Kind) = try .initCapacity(arena, kinds.len);
    var owed: std.ArrayList(u32) = try .initCapacity(arena, kinds.len);

    for (kinds, 0..) |kind, index| {
        if (kind == .paren_open) {
            depth += 1;

            if (functions_at(kinds, index + 1)) {
                owed.appendAssumeCapacity(depth);

                continue;
            }
        }

        if (kind == .paren_close) {
            const owed_here = if (owed.last()) |top| top == depth else false;

            depth -|= 1;

            if (owed_here) {
                _ = owed.pop();

                continue;
            }
        }

        held.appendAssumeCapacity(kind);
    }

    assert(held.items.len <= kinds.len);

    return held.items;
}

fn closing(comptime side: type, held: []const side.Item, from: usize) bool {
    assert(held.len <= std.math.maxInt(u32));
    assert(from < std.math.maxInt(u32));

    var at = from;

    while (at < held.len) {
        if (!side.commented(held[at])) break;

        at += 1;
    }

    assert(at >= from);

    if (at >= held.len) return false;
    return side.shuts(held[at]);
}

fn colons(arena: std.mem.Allocator, held: []const Pair) ![]const bool {
    assert(held.len <= std.math.maxInt(u32));

    const found = try arena.alloc(bool, held.len);
    var owed: std.ArrayList(u32) = try .initCapacity(arena, held.len + 1);

    @memset(found, false);
    owed.appendAssumeCapacity(0);

    for (held, 0..) |pair, at| {
        const colon_next = if (at + 1 < held.len) held[at + 1].kind == .colon else false;
        const top = &owed.items[owed.items.len - 1];

        switch (pair.kind) {
            .brace_open, .bracket_open, .paren_open, .substitution_start => {
                owed.appendAssumeCapacity(0);
            },
            .brace_close, .bracket_close, .paren_close => {
                if (owed.items.len > 1) _ = owed.pop();
            },
            .comma, .semicolon => top.* = 0,
            .case_keyword, .question => {
                if (!colon_next) top.* += 1;
            },
            .colon => {
                if (top.* > 0) {
                    top.* -= 1;
                    found[at] = true;
                }
            },
            else => {},
        }
    }

    assert(owed.items.len > 0);
    assert(found.len == held.len);

    return found;
}

fn corpus_selected(basename: []const u8) bool {
    assert(basename.len > 0);

    const dotted = std.Io.Dir.path.extension(basename);
    if (dotted.len < 2) return false;
    return Language.of_extension(dotted[1..]) == .javascript;
}

fn divergence(
    comptime side: type,
    source: []const side.Item,
    printed: []const side.Item,
) ?Divergence {
    assert(source.len <= std.math.maxInt(u32));
    assert(printed.len <= std.math.maxInt(u32));

    var held: usize = 0;
    var at: usize = 0;

    while (at < printed.len) {
        const carried = printed[at];

        if (held < source.len) {
            if (side.eql(source[held], carried)) {
                at += 1;
                held += 1;

                continue;
            }

            if (passable(side, source, held)) {
                held += 1;

                continue;
            }
        }

        const dropped_here = side.opens(carried) or side.closes(carried) or
            side.semicolon(carried);

        if (dropped_here) {
            at += 1;

            continue;
        }

        return .{ .held = held, .at = at };
    }

    while (held < source.len) {
        if (!passable(side, source, held)) break;

        held += 1;
    }

    assert(held <= source.len);

    if (held == source.len) return null;
    return .{ .held = held, .at = printed.len };
}

fn dropped(comptime side: type, held: []const side.Item, pairs: []const usize, index: usize) bool {
    assert(index < held.len);
    assert(pairs.len == held.len);

    if (!side.opens(held[index])) return false;
    if (pairs[index] <= index) return false;
    if (side.calls(held, index)) return false;
    return assigns(side, held, index, pairs[index]);
}

fn expect_formatted(source: []const u8, wanted: []const u8) !void {
    const gpa = std.testing.allocator;

    assert(source.len > 0);
    assert(wanted.len > 0);

    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var out: Buffer = try .init(gpa, out_bytes_max);
    defer out.deinit(gpa);

    try held.format(source, &out);
    try std.testing.expectEqualStrings(wanted, out.const_slice());

    var again: Buffer = try .init(gpa, out_bytes_max);
    defer again.deinit(gpa);

    try held.format(wanted, &again);
    try std.testing.expectEqualStrings(wanted, again.const_slice());
}

fn expect_settled(source: []const u8) !void {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var twice: Twice = undefined;

    try twice.init(gpa);
    defer twice.deinit(gpa);

    assert(source.len > 0);

    try twice.held.format(source, &twice.first);

    const once = twice.first.const_slice();
    const fixture: Fixture = .{ .name = "settled", .source = source };

    try relations_hold(&twice.held, arena.allocator(), fixture, once);
    try twice.held.format(once, &twice.second);
    try std.testing.expectEqualStrings(once, twice.second.const_slice());
}

fn expect_text(
    name: []const u8,
    comptime message: []const u8,
    expected: []const u8,
    actual: []const u8,
) !void {
    comptime assert(message.len > 0);
    assert(name.len > 0);
    assert(expected.len <= std.math.maxInt(u32));
    assert(actual.len <= std.math.maxInt(u32));

    if (std.mem.eql(u8, expected, actual)) return;

    std.debug.print("{s} " ++ message ++ "\n", .{name});

    return std.testing.expectEqualStrings(expected, actual);
}

fn fixture_less_than(context: void, left: Fixture, right: Fixture) bool {
    _ = context;

    assert(left.name.len > 0);
    assert(right.name.len > 0);

    return std.mem.lessThan(u8, left.name, right.name);
}

fn fixtures(gpa: std.mem.Allocator) !std.ArrayList(Fixture) {
    const io = std.testing.io;
    var found: std.ArrayList(Fixture) = .empty;
    errdefer fixtures_free(gpa, &found);

    var directory = try std.Io.Dir.cwd().openDir(io, fixture_root, .{ .iterate = true });
    defer directory.close(io);

    var iterator = directory.iterate();

    for (0..file_count_max) |_| {
        const entry = try iterator.next(io) orelse break;
        if (!std.mem.eql(u8, std.Io.Dir.path.extension(entry.name), extension)) continue;

        const limit: std.Io.Limit = .limited(source_bytes_max);
        const source = try directory.readFileAlloc(io, entry.name, gpa, limit);
        errdefer gpa.free(source);

        const name = try gpa.dupe(u8, entry.name);
        errdefer gpa.free(name);

        try found.append(gpa, .{ .name = name, .source = source });
    }

    std.mem.sort(Fixture, found.items, {}, fixture_less_than);

    try require(found.items.len > fixture_count_min, "{s} holds too few fixtures", .{fixture_root});

    assert(found.items.len <= file_count_max);
    assert(fixture_less_than({}, found.items[0], found.items[1]));

    return found;
}

fn fixtures_free(gpa: std.mem.Allocator, found: *std.ArrayList(Fixture)) void {
    assert(found.items.len <= found.capacity);
    assert(found.items.len <= file_count_max);

    for (found.items) |fixture| {
        gpa.free(fixture.name);
        gpa.free(fixture.source);
    }

    found.deinit(gpa);
    found.* = undefined;
}

fn functions_at(kinds: []const Kind, at: usize) bool {
    if (at >= kinds.len) return false;
    if (kinds[at] == .function_keyword) return true;
    if (kinds[at] != .async_keyword) return false;
    if (at + 1 >= kinds.len) return false;
    return kinds[at + 1] == .function_keyword;
}

fn jsx_child_space(source: []const u8, held: []const Pair, index: usize) ?JsxSpace {
    assert(index < held.len);
    assert(source.len <= std.math.maxInt(u32));

    const pair = held[index];

    if (pair.kind == .jsx_chars) {
        const text = pair.token.text(source);

        assert(text.len > 0);

        if (std.mem.trim(u8, text, jsx_blanks).len > 0) return null;

        const lined = std.mem.findAny(u8, text, "\n\r") != null;
        return .{ .meaningful = !lined, .width = 1 };
    }

    if (pair.kind != .brace_open) return null;
    if (index + 2 >= held.len) return null;
    if (held[index + 1].kind != .string) return null;
    if (held[index + 2].kind != .brace_close) return null;

    const text = held[index + 1].token.text(source);
    const spaced = std.mem.eql(u8, text, "\" \"") or std.mem.eql(u8, text, "' '");
    if (!spaced) return null;
    return .{ .meaningful = true, .width = 3 };
}

fn jsx_framed(frames: *std.ArrayList(JsxFrame), kind: Kind) void {
    assert(frames.items.len < frames.capacity);
    assert(kind.is_token());

    const top = frames.last() orelse {
        if (kind == .jsx_tag_start) frames.appendAssumeCapacity(.tag);

        return;
    };

    const at = frames.items.len - 1;

    switch (top) {
        .children => switch (kind) {
            .brace_open => frames.appendAssumeCapacity(.hole),
            .jsx_tag_start => frames.appendAssumeCapacity(.tag),
            .jsx_tag_start_close => frames.items[at] = .closing,
            else => {},
        },
        .closing => {
            if (kind == .jsx_tag_end) _ = frames.pop();
        },
        .hole => switch (kind) {
            .brace_open, .substitution_start => frames.appendAssumeCapacity(.hole),
            .brace_close => _ = frames.pop(),
            .jsx_tag_start => frames.appendAssumeCapacity(.tag),
            else => {},
        },
        .tag => switch (kind) {
            .brace_open => frames.appendAssumeCapacity(.hole),
            .jsx_tag_end => frames.items[at] = .children,
            .jsx_tag_end_self => _ = frames.pop(),
            .jsx_tag_start => frames.appendAssumeCapacity(.tag),
            else => {},
        },
    }
}

fn jsx_spaced(arena: std.mem.Allocator, source: []const u8, held: []const Pair) ![]const Pair {
    assert(source.len <= std.math.maxInt(u32));
    assert(held.len <= std.math.maxInt(u32));

    var found: std.ArrayList(Pair) = try .initCapacity(arena, held.len);
    var frames: std.ArrayList(JsxFrame) = try .initCapacity(arena, held.len);
    var index: usize = 0;

    while (index < held.len) {
        const pair = held[index];
        const childed = if (frames.last()) |top| top == .children else false;

        if (childed) {
            if (jsx_child_space(source, held, index)) |space| {
                if (space.meaningful) jsx_text_append(&found, pair);

                index += space.width;

                continue;
            }

            if (pair.kind == .jsx_chars) {
                jsx_text_append(&found, pair);
                index += 1;

                continue;
            }
        }

        jsx_framed(&frames, pair.kind);
        found.appendAssumeCapacity(pair);
        index += 1;
    }

    assert(found.items.len <= held.len);

    return found.items;
}

fn jsx_text_append(found: *std.ArrayList(Pair), pair: Pair) void {
    assert(found.items.len < found.capacity);
    assert(pair.kind.is_token());

    if (found.last()) |top| {
        if (top.kind == .jsx_chars) return;
    }

    found.appendAssumeCapacity(.{ .kind = .jsx_chars, .token = pair.token });
}

fn kept(
    held: *Held,
    arena: std.mem.Allocator,
    name: []const u8,
    source: []const u8,
    printed: []const u8,
) !void {
    assert(name.len > 0);
    assert(source.len <= std.math.maxInt(u32));
    assert(printed.len <= std.math.maxInt(u32));

    const comments_before = try trimmed(arena, try held.comments(arena, source));
    const comments_after = try trimmed(arena, try held.comments(arena, printed));

    try expect_text(name, "lost a comment", comments_before, comments_after);

    const templates_before = try held.templates(arena, source);
    const templates_after = try held.templates(arena, printed);
    const message = "{s} edited a template's characters";

    try require(texts_equal(templates_before, templates_after), message, .{name});
}

fn key_kind(source: []const u8, held: []const Pair, asked: []const bool, index: usize) ?Kind {
    assert(index < held.len);
    assert(asked.len == held.len);
    assert(source.len <= std.math.maxInt(u32));

    const at = key_colon(held, index) orelse return key_assigned(source, held, index);
    if (asked[at]) return null;

    const text = held[index].token.text(source);

    if (bodied(text)) |body| {
        if (numbered_key(body)) return .number;
    }

    if (bare_key(text) == null) return null;
    return .identifier;
}

fn key_assigned(source: []const u8, held: []const Pair, index: usize) ?Kind {
    assert(index < held.len);

    if (held[index].kind != .string) return null;
    if (index + 1 >= held.len) return null;
    if (held[index + 1].kind != .equal) return null;
    assert(source.len <= std.math.maxInt(u32));

    const text = held[index].token.text(source);

    assert(text.len > 0);

    if (bodied(text)) |body| {
        if (numbered_key(body)) return .number;
    }

    if (named_key(text) == null) return null;
    return .identifier;
}

fn key_colon(held: []const Pair, index: usize) ?usize {
    assert(index < held.len);

    if (index + 1 >= held.len) return null;

    if (held[index + 1].kind == .colon) {
        assert(index + 1 < std.math.maxInt(u32));

        return index + 1;
    }

    if (held[index + 1].kind != .question) return null;
    if (index + 2 >= held.len) return null;

    if (held[index + 2].kind == .colon) {
        assert(index + 2 < std.math.maxInt(u32));

        return index + 2;
    }

    return null;
}

fn keyed(arena: std.mem.Allocator, source: []const u8, held: []const Pair) ![]const Kind {
    assert(source.len <= std.math.maxInt(u32));
    assert(held.len <= std.math.maxInt(u32));

    const asked = try colons(arena, held);
    const found = try arena.alloc(Kind, held.len);

    assert(asked.len == held.len);

    for (held, 0..) |pair, index| {
        found[index] = key_kind(source, held, asked, index) orelse pair.kind;
    }

    assert(found.len == held.len);

    return found;
}

fn kinds_skipped(kind: Kind) bool {
    assert(kind.is_token());

    const name = kind.name();

    assert(name.len > 0);

    for (skipped_names) |skipped| {
        if (std.mem.eql(u8, name, skipped)) return true;
    }

    return false;
}

fn line_trimmed(line: []const u8) []const u8 {
    assert(line.len <= std.math.maxInt(u32));

    var start: usize = 0;
    var end: usize = line.len;

    for (0..line.len) |_| {
        const width = space_width(line[start..end], .leading);
        if (width == 0) break;

        start += width;
    }

    for (0..line.len) |_| {
        const width = space_width(line[start..end], .trailing);
        if (width == 0) break;

        end -= width;
    }

    assert(start <= end);
    assert(end <= line.len);

    return line[start..end];
}

fn lines_of(bytes: []const u8, first: u32, last: u32) []const u8 {
    assert(first <= last);
    assert(bytes.len <= std.math.maxInt(u32));

    var line: u32 = 0;
    var start: usize = 0;
    var end: usize = bytes.len;

    for (bytes, 0..) |byte, offset| {
        if (byte != '\n') continue;

        line += 1;

        if (line == first) start = offset + 1;

        if (line == last + 1) {
            end = offset + 1;

            break;
        }
    }

    assert(start <= end);

    return bytes[start..end];
}

fn listed(
    comptime side: type,
    arena: std.mem.Allocator,
    held: []const side.Item,
) ![]const side.Item {
    assert(held.len <= std.math.maxInt(u32));

    var found: std.ArrayList(side.Item) = try .initCapacity(arena, held.len);

    for (held, 0..) |item, index| {
        if (side.separates(item)) {
            if (closing(side, held, index + 1)) continue;
        }

        found.appendAssumeCapacity(item);
    }

    assert(found.items.len <= held.len);

    return found.items;
}

fn named_key(text: []const u8) ?[]const u8 {
    if (text.len < 2) return null;

    const quote = text[0];
    const quoted = quote == '"' or quote == '\'';
    if (!quoted) return null;
    if (text[text.len - 1] != quote) return null;
    return bare_name(text[1 .. text.len - 1]);
}

fn parenthesised(arena: std.mem.Allocator, kinds: []const Kind) ![]const Kind {
    assert(kinds.len <= std.math.maxInt(u32));

    var held: std.ArrayList(Kind) = try .initCapacity(arena, kinds.len);
    var index: usize = 0;

    while (index < kinds.len) {
        if (index + 3 < kinds.len) {
            const lone = kinds[index] == .paren_open and kinds[index + 1] == .identifier and
                kinds[index + 2] == .paren_close and kinds[index + 3] == .arrow;

            if (lone) {
                held.appendAssumeCapacity(.identifier);
                index += 3;

                continue;
            }
        }

        held.appendAssumeCapacity(kinds[index]);
        index += 1;
    }

    assert(held.items.len <= kinds.len);

    return held.items;
}

fn partners(comptime side: type, arena: std.mem.Allocator, held: []const side.Item) ![]usize {
    assert(held.len <= std.math.maxInt(u32));

    const found = try arena.alloc(usize, held.len);
    var stack: std.ArrayList(usize) = try .initCapacity(arena, held.len);

    for (found, 0..) |*slot, index| slot.* = index;

    for (held, 0..) |item, at| {
        if (side.opens(item)) {
            stack.appendAssumeCapacity(at);

            continue;
        }

        if (!side.closes(item)) continue;

        const from = stack.pop() orelse continue;

        found[from] = at;
        found[at] = from;
    }

    assert(found.len == held.len);
    assert(stack.items.len <= held.len);

    return found;
}

fn passable(comptime side: type, source: []const side.Item, held: usize) bool {
    assert(held < source.len);

    const item = source[held];
    if (side.opens(item)) return true;
    if (side.closes(item)) return true;
    if (!side.semicolon(item)) return false;
    return voided(side, source, held);
}

fn read_under(gpa: std.mem.Allocator, root: []const u8, name: []const u8) ![]u8 {
    assert(root.len > 0);
    assert(name.len > 0);

    var path_buffer: [path_bytes_max]u8 = undefined;
    const path = try std.mem.print(&path_buffer, "{s}/{s}", .{ root, name });
    const limit: std.Io.Limit = .limited(source_bytes_max);

    assert(path.len > name.len);

    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, gpa, limit);
}

fn related(arena: std.mem.Allocator, kinds: []const Kind) ![]const Kind {
    assert(kinds.len <= std.math.maxInt(u32));

    const step_listed = try listed(kind_side, arena, kinds);
    const step_parenthesised = try parenthesised(arena, step_listed);
    const step_called = try called(arena, step_parenthesised);
    const step_assigned = try assigned(kind_side, arena, step_called);

    return unwrapped(kind_side, arena, step_assigned);
}

fn related_words(arena: std.mem.Allocator, words: []const []const u8) ![]const []const u8 {
    assert(words.len <= std.math.maxInt(u32));

    const step_separated = try listed(word_side, arena, words);
    const step_bracketed = try bracketed(arena, step_separated);
    const step_assigned = try assigned(word_side, arena, step_bracketed);

    return unwrapped(word_side, arena, step_assigned);
}

fn relations_hold(held: *Held, arena: std.mem.Allocator, fixture: Fixture, once: []const u8) !void {
    assert(once.len <= std.math.maxInt(u32));
    assert(fixture.name.len > 0);

    const before_kinds = try commented(arena, try held.kinds(arena, fixture.source));
    const after_kinds = try commented(arena, try held.kinds(arena, once));
    const before = try related(arena, before_kinds);
    const after = try related(arena, after_kinds);

    if (divergence(kind_side, before, after)) |diverged| {
        std.debug.print("{s} lost a token\n", .{fixture.name});
        window_print("  source ", before, diverged.held);
        window_print("  printed", after, diverged.at);

        return error.TestUnexpectedResult;
    }

    try kept(held, arena, fixture.name, fixture.source, once);
}

fn commented(arena: std.mem.Allocator, kinds: []const Kind) ![]const Kind {
    assert(kinds.len <= std.math.maxInt(u32));

    var found: std.ArrayList(Kind) = try .initCapacity(arena, kinds.len);

    for (kinds) |kind| {
        if (kind == .comment) continue;

        found.appendAssumeCapacity(kind);
    }

    assert(found.items.len <= kinds.len);

    return found.items;
}

fn is_complete(result: FormatterError!void) bool {
    if (std.meta.isError(result)) return false;

    return true;
}

fn is_refused(result: FormatterError!void) bool {
    if (!std.meta.isError(result)) return false;

    result catch |err| switch (err) {
        error.OutputExhausted => return false,
        error.SourceInvalid => return true,
    };

    return false;
}

fn outcome_name(result: FormatterError!void) []const u8 {
    result catch |err| return @errorName(err);

    return "complete";
}

fn require(condition: bool, comptime format: []const u8, arguments: anytype) !void {
    comptime assert(format.len > 0);
    comptime assert(@typeInfo(@TypeOf(arguments)) == .@"struct");

    if (condition) return;

    std.debug.print(format ++ "\n", arguments);

    return error.TestUnexpectedResult;
}

fn settles(
    held: *Held,
    once: []const u8,
    second: *Buffer,
    name: []const u8,
    residue: *const oracle.Residue,
) !bool {
    assert(once.len <= std.math.maxInt(u32));
    assert(name.len > 0);

    const formatted = is_complete(held.format(once, second));

    if (residue.contains(name)) {
        try require(
            !formatted or !std.mem.eql(u8, second.const_slice(), once),
            "{s} is a fixed point and needs no residue row",
            .{name},
        );

        return true;
    }

    try require(formatted, "{s}", .{name});
    try expect_text(name, "is not idempotent", once, second.const_slice());

    return false;
}

fn skipped_at(skips: *std.ArrayList(usize), index: usize) bool {
    const top = skips.last() orelse return false;
    if (top != index) return false;

    _ = skips.pop();

    return true;
}

fn space_width(text: []const u8, end: Edge) usize {
    assert(text.len <= std.math.maxInt(u32));

    if (text.len == 0) return 0;

    const byte = switch (end) {
        .leading => text[0],
        .trailing => text[text.len - 1],
    };

    if (std.mem.findScalar(u8, ascii_whitespace ++ "\x0b", byte) != null) return 1;

    for (unicode_spaces) |space| {
        const found = switch (end) {
            .leading => std.mem.startsWith(u8, text, space),
            .trailing => std.mem.endsWith(u8, text, space),
        };

        if (found) return space.len;
    }

    return 0;
}

fn string_keyed(source: []const u8, tokens: []const Token, index: usize) bool {
    assert(index < tokens.len);

    if (index + 1 >= tokens.len) return false;
    assert(source.len <= std.math.maxInt(u32));

    const next = tokens[index + 1].text(source);
    if (std.mem.eql(u8, next, ":")) return true;
    if (!std.mem.eql(u8, next, "?")) return false;
    if (index + 2 >= tokens.len) return false;
    return std.mem.eql(u8, tokens[index + 2].text(source), ":");
}

fn terminated(source: []const Kind, printed: []const Kind) bool {
    assert(source.len <= std.math.maxInt(u32));
    assert(printed.len <= std.math.maxInt(u32));

    return divergence(kind_side, source, printed) == null;
}

fn texts_equal(before: []const []const u8, after: []const []const u8) bool {
    if (before.len != after.len) return false;

    for (before, after) |one, two| {
        if (!std.mem.eql(u8, one, two)) return false;
    }

    return true;
}

fn trimmed(arena: std.mem.Allocator, comments: []const []const u8) ![]const u8 {
    assert(comments.len <= std.math.maxInt(u32));

    var joined: std.ArrayList(u8) = .empty;

    for (comments) |comment| {
        var lines = std.mem.splitScalar(u8, comment, '\n');
        var line_index: usize = 0;

        while (lines.next()) |line| : (line_index += 1) {
            assert(line_index <= comment.len);

            if (line_index > 0) try joined.append(arena, '\n');

            try joined.appendSlice(arena, line_trimmed(line));
        }
    }

    return joined.items;
}

fn unassigned(
    comptime side: type,
    arena: std.mem.Allocator,
    held: []const side.Item,
) ![]const side.Item {
    assert(held.len <= std.math.maxInt(u32));

    const pairs = try partners(side, arena, held);
    var found: std.ArrayList(side.Item) = try .initCapacity(arena, held.len);
    var skips: std.ArrayList(usize) = try .initCapacity(arena, held.len);

    for (held, 0..) |item, index| {
        if (skipped_at(&skips, index)) continue;

        if (dropped(side, held, pairs, index)) {
            skips.appendAssumeCapacity(pairs[index]);

            continue;
        }

        found.appendAssumeCapacity(item);
    }

    assert(found.items.len <= held.len);

    return found.items;
}

fn unwrapped(
    comptime side: type,
    arena: std.mem.Allocator,
    held: []const side.Item,
) ![]const side.Item {
    assert(held.len <= std.math.maxInt(u32));

    const pairs = try partners(side, arena, held);
    var found: std.ArrayList(side.Item) = try .initCapacity(arena, held.len);
    var skips: std.ArrayList(usize) = try .initCapacity(arena, held.len);
    var index: usize = 0;

    while (index < held.len) {
        if (wrapping(side, held, pairs, index)) {
            found.appendAssumeCapacity(held[index]);
            skips.appendAssumeCapacity(pairs[index + 1]);
            index += 2;

            continue;
        }

        if (!skipped_at(&skips, index)) found.appendAssumeCapacity(held[index]);

        index += 1;
    }

    assert(found.items.len <= held.len);

    return found.items;
}

fn voided(comptime side: type, held: []const side.Item, at: usize) bool {
    assert(at <= held.len);

    if (at == 0) return true;
    return side.voids(held[at - 1]);
}

fn window_print(comptime label: []const u8, held: []const Kind, at: usize) void {
    assert(label.len > 0);
    assert(held.len <= std.math.maxInt(u32));
    assert(at < std.math.maxInt(u32));

    const from = at -| window_width;
    const to = @min(held.len, at + window_width);

    assert(from <= to);

    std.debug.print(label ++ " {d} of {d}", .{ at, held.len });

    for (held[from..to]) |kind| std.debug.print(" {s}", .{kind.name()});

    std.debug.print("\n", .{});
}

fn word_in(word: []const u8, comptime set: []const []const u8) bool {
    assert(word.len <= std.math.maxInt(u32));
    assert(set.len <= std.math.maxInt(u32));

    inline for (set) |member| {
        if (std.mem.eql(u8, word, member)) return true;
    }

    return false;
}

fn word_opens_name(word: []const u8) bool {
    assert(word.len > 0);

    const leading = word[0];

    if (leading < 0x80) {
        return std.ascii.isAlphanumeric(leading) or leading == '_' or leading == '$';
    }

    const width = std.unicode.utf8ByteSequenceLength(leading) catch return false;
    if (width > word.len) return false;

    const scalar = switch (width) {
        2 => std.unicode.utf8Decode2(word[0..2].*),
        3 => std.unicode.utf8Decode3(word[0..3].*),
        4 => std.unicode.utf8Decode4(word[0..4].*),
        else => unreachable,
    } catch return false;

    assert(scalar >= 0x80);

    return unicode.is_alphanumeric(scalar);
}

fn word_skipped(token: Token) bool {
    if (token.length == 0) return true;
    return token.kind == .newline;
}

fn word_written(
    arena: std.mem.Allocator,
    source: []const u8,
    tokens: []const Token,
    index: usize,
) ![]const u8 {
    assert(tokens.len <= std.math.maxInt(u32));
    assert(index < tokens.len);

    const token = tokens[index];

    assert(token.length > 0);
    assert(token.end() <= source.len);

    if (token.kind == .number) {
        var form: Buffer = try .init(arena, number_bytes_max);

        renumbered(&form, token.text(source)) catch unreachable;

        return form.const_slice();
    }

    if (token.kind != .string) return token.text(source);
    if (!string_keyed(source, tokens, index)) return "<string>";
    return named_key(token.text(source)) orelse "<string>";
}

fn wrapping(comptime side: type, held: []const side.Item, pairs: []const usize, index: usize) bool {
    assert(index < held.len);
    assert(pairs.len == held.len);

    if (!side.wraps(held[index])) return false;
    if (index + 1 >= held.len) return false;
    if (!side.opens(held[index + 1])) return false;

    const close = pairs[index + 1];
    if (close <= index + 1) return false;
    if (close + 1 >= held.len) return true;
    return side.ends_wrap(held[close + 1]);
}

fn write_under(root: []const u8, name: []const u8, data: []const u8) !void {
    assert(root.len <= std.math.maxInt(u32));
    assert(name.len > 0);
    assert(data.len <= std.math.maxInt(u32));

    var path_buffer: [path_bytes_max]u8 = undefined;
    const path = try std.mem.print(&path_buffer, "{s}/{s}", .{ root, name });

    assert(path.len == root.len + name.len + 1);

    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = data });
}

test "formatting formatted output changes nothing" {
    const gpa = std.testing.allocator;
    var twice: Twice = undefined;

    try twice.init(gpa);
    defer twice.deinit(gpa);

    var found = try fixtures(gpa);
    defer fixtures_free(gpa, &found);

    for (found.items) |fixture| {
        twice.held.format(fixture.source, &twice.first) catch continue;

        const once = twice.first.const_slice();
        const second = twice.held.format(once, &twice.second);

        try require(is_complete(second), "{s}", .{fixture.name});
        try expect_text(fixture.name, "is not idempotent", once, twice.second.const_slice());
    }
}

test "formatting keeps every token it was given" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var out: Buffer = try .init(gpa, out_bytes_max);
    defer out.deinit(gpa);

    var found = try fixtures(gpa);
    defer fixtures_free(gpa, &found);

    for (found.items) |fixture| {
        held.format(fixture.source, &out) catch continue;

        _ = arena.reset(.retain_capacity);

        const before_kinds = try held.kinds(arena.allocator(), fixture.source);
        const after_kinds = try held.kinds(arena.allocator(), out.const_slice());
        const before = try related(arena.allocator(), before_kinds);
        const after = try related(arena.allocator(), after_kinds);

        try require(terminated(before, after), "{s} lost or gained a token", .{fixture.name});
    }
}

test "formatting keeps every comment it was given" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var out: Buffer = try .init(gpa, out_bytes_max);
    defer out.deinit(gpa);

    var found = try fixtures(gpa);
    defer fixtures_free(gpa, &found);

    for (found.items) |fixture| {
        held.format(fixture.source, &out) catch continue;

        _ = arena.reset(.retain_capacity);

        try kept(&held, arena.allocator(), fixture.name, fixture.source, out.const_slice());
    }
}

test "a dump writes the formatted fixtures" {
    const gpa = std.testing.allocator;
    var root_bytes: [environment.value_bytes_max]u8 = undefined;
    const root = environment.get(dump_variable, &root_bytes) orelse return;
    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var out: Buffer = try .init(gpa, out_bytes_max);
    defer out.deinit(gpa);

    var found = try fixtures(gpa);
    defer fixtures_free(gpa, &found);

    for (found.items) |fixture| {
        held.format(fixture.source, &out) catch continue;

        try write_under(root, fixture.name, out.const_slice());
    }
}

test "every jsx fixture is formatted or refused by its own row" {
    const gpa = std.testing.allocator;
    var carried = try oracle.residue_of(gpa, residue_format_name, &every_category);
    defer carried.deinit(gpa);

    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var out: Buffer = try .init(gpa, out_bytes_max);
    defer out.deinit(gpa);

    var found = try fixtures(gpa);
    defer fixtures_free(gpa, &found);

    var walked: u32 = 0;

    for (found.items) |fixture| {
        if (!std.mem.startsWith(u8, fixture.name, "jsx_")) continue;

        walked += 1;

        const outcome = held.format(fixture.source, &out);
        if (is_complete(outcome)) continue;

        try require(is_refused(outcome), "{s}", .{fixture.name});

        const message = "{s} is refused and no residue row names it";

        try require(carried.contains(fixture.name), message, .{fixture.name});
    }

    try require(walked == jsx_fixture_count, "the jsx fixtures are not walked", .{});
}

test "the formatted output matches the oracle modulo residue" {
    const gpa = std.testing.allocator;
    var carried = try oracle.residue_of(gpa, residue_format_name, &every_category);
    defer carried.deinit(gpa);

    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var out: Buffer = try .init(gpa, out_bytes_max);
    defer out.deinit(gpa);

    var found = try fixtures(gpa);
    defer fixtures_free(gpa, &found);

    var compared: u32 = 0;

    for (found.items) |fixture| {
        if (carried.contains(fixture.name)) continue;

        const outcome = held.format(fixture.source, &out);
        const refused = "{s} is refused and no residue row names it";

        try require(is_complete(outcome), refused, .{fixture.name});

        const golden = try read_under(gpa, golden_root, fixture.name);
        defer gpa.free(golden);

        const message = "diverges from biome and no residue row names it";

        try expect_text(fixture.name, message, golden, out.const_slice());

        compared += 1;
    }

    try require(
        compared >= floor.fixture_format_javascript,
        "the JavaScript fixtures lost a formatting: {d} compared, floor {d}",
        .{ compared, floor.fixture_format_javascript },
    );
}

test "every residue row names a fixture that diverges" {
    const gpa = std.testing.allocator;
    var carried = try oracle.residue_of(gpa, residue_format_name, &every_category);
    defer carried.deinit(gpa);

    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var out: Buffer = try .init(gpa, out_bytes_max);
    defer out.deinit(gpa);

    for (carried.fixtures.items) |name| {
        const source = try read_under(gpa, fixture_root, name);
        defer gpa.free(source);

        held.format(source, &out) catch continue;

        const golden = try read_under(gpa, golden_root, name);
        defer gpa.free(golden);

        const diverged = !std.mem.eql(u8, out.const_slice(), golden);

        try require(diverged, "{s} matches biome and needs no residue row", .{name});
    }
}

test "a file that does not parse is refused" {
    const gpa = std.testing.allocator;
    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var out: Buffer = try .init(gpa, out_bytes_max);
    defer out.deinit(gpa);

    try std.testing.expectError(error.SourceInvalid, held.format("function f( {\n", &out));
    try std.testing.expect(out.empty());
}

test "a source that never closes a string or a comment is refused" {
    const gpa = std.testing.allocator;
    const sources = [_][]const u8{ "' ", "\":\\\\", "/* ", "const a = \"open\n" };
    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var out: Buffer = try .init(gpa, out_bytes_max);
    defer out.deinit(gpa);

    for (sources) |source| {
        const outcome = held.format(source, &out);

        try require(is_refused(outcome), "{s} for \"{s}\"", .{ outcome_name(outcome), source });
    }
}

test "an operator does not reach into the comment behind it" {
    const gpa = std.testing.allocator;
    const source = "tyy<<!--y[\n1";
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var twice: Twice = undefined;

    try twice.init(gpa);
    defer twice.deinit(gpa);

    try std.testing.expectError(error.SourceInvalid, twice.held.format("tyy<<!--y[", &twice.first));
    try twice.held.format(source, &twice.first);

    const once = twice.first.const_slice();
    const comments_source = try twice.held.comments(arena.allocator(), source);
    const comments_once = try twice.held.comments(arena.allocator(), once);

    try std.testing.expect(texts_equal(comments_source, comments_once));
    try twice.held.format(once, &twice.second);
    try std.testing.expectEqualStrings(once, twice.second.const_slice());
}

test "a shift owed its left operand before a slash is refused" {
    const gpa = std.testing.allocator;
    const sources = [_][]const u8{ "<</<!--/ ", "<</<!--/\x0c" };
    var twice: Twice = undefined;

    try twice.init(gpa);
    defer twice.deinit(gpa);

    for (sources) |source| {
        const outcome = twice.held.format(source, &twice.first);

        try require(is_refused(outcome), "{s} for \"{s}\"", .{ outcome_name(outcome), source });
    }
}

test "an expression owed an operand or a closer is refused" {
    const gpa = std.testing.allocator;
    const sources = [_][]const u8{ "x=>,", "x=>=", "import.=", "{}`", "+?:=", "return&x", "f(a" };
    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var out: Buffer = try .init(gpa, out_bytes_max);
    defer out.deinit(gpa);

    for (sources) |source| {
        const outcome = held.format(source, &out);

        try require(is_refused(outcome), "{s} for \"{s}\"", .{ outcome_name(outcome), source });
    }
}

test "a spaced shift keeps its spaces" {
    try expect_formatted("a = b << c;\n", "a = b << c;\n");
}

test "a string takes the quote biome prefers" {
    const gpa = std.testing.allocator;

    const cases = [_][2][]const u8{
        .{ "a = 'x';\n", "a = \"x\";\n" },
        .{ "a = \"x\";\n", "a = \"x\";\n" },
        .{ "a = 'it\\'s';\n", "a = \"it's\";\n" },
        .{ "a = 'say \"hi\"';\n", "a = 'say \"hi\"';\n" },
        .{ "a = 'both \" and \\'';\n", "a = \"both \\\" and '\";\n" },
        .{ "a = \"\\\"\";\n", "a = '\"';\n" },
        .{ "a = \"\\'\";\n", "a = \"\\'\";\n" },
        .{ "a = '\\n\\t';\n", "a = \"\\n\\t\";\n" },
    };

    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    for (cases) |case| {
        var out: Buffer = try .init(gpa, out_bytes_max);
        defer out.deinit(gpa);

        try held.format(case[0], &out);
        try std.testing.expectEqualStrings(case[1], out.const_slice());
    }
}

test "a range reads back the lines it names" {
    const gpa = std.testing.allocator;
    const source = "function f() {\nlet x=1;\nreturn x;\n}\n";
    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var whole: Buffer = try .init(gpa, out_bytes_max);
    defer whole.deinit(gpa);

    var out: Buffer = try .init(gpa, out_bytes_max);
    defer out.deinit(gpa);

    try held.format(source, &whole);

    const formatted = whole.const_slice();
    const span = try held.range(source, .{ .first = 1, .last = 2 }, &out);

    try std.testing.expectEqualStrings(formatted, out.const_slice());
    try std.testing.expectEqualStrings(lines_of(formatted, 1, 2), span.text(out.const_slice()));
}

test "the three relations hold over the corpus" {
    const gpa = std.testing.allocator;
    const root = corpus.named(.root) orelse return;
    var residue = try oracle.residue_of(gpa, residue_relations_name, &every_unsettled);
    defer residue.deinit(gpa);

    var files = try corpus.collect(gpa, root, source_bytes_max, corpus_selected);
    defer files.deinit(gpa);

    const stride = corpus.stride();

    files.strided(gpa, stride);

    var tally: RelationsWorker.Tally = .{ .settling = 0 };

    try stripe.run(RelationsWorker, gpa, &.{ .residue = &residue }, files.slice(), &tally);

    try require(
        stride > 1 or tally.settling == residue.fixtures.items.len,
        "{d} of the {d} residue rows name a corpus file the walk reached",
        .{ tally.settling, residue.fixtures.items.len },
    );
}

test "formatting keeps every word it was given" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var out: Buffer = try .init(gpa, out_bytes_max);
    defer out.deinit(gpa);

    var found = try fixtures(gpa);
    defer fixtures_free(gpa, &found);

    for (found.items) |fixture| {
        held.format(fixture.source, &out) catch continue;

        _ = arena.reset(.retain_capacity);

        const before_words = try held.words(arena.allocator(), fixture.source);
        const after_words = try held.words(arena.allocator(), out.const_slice());
        const before = try related_words(arena.allocator(), before_words);
        const after = try related_words(arena.allocator(), after_words);
        const ended = divergence(word_side, before, after) == null;
        const message = "{s} split, joined, lost, or gained a word";

        try require(ended, message, .{fixture.name});
    }
}

test "a statement the source left without one gains the separator the reference writes" {
    const source = "import fs from \"node:fs\"\n" ++
        "const a = 1\n" ++
        "let b = class {}\n" ++
        "export class D {}\n" ++
        "export default class E {}\n" ++
        "export function f() {}\n" ++
        "export { a }\n" ++
        "class C {\n" ++
        "    field = 1\n" ++
        "    method() {}\n" ++
        "}\n" ++
        "function j() {\n" ++
        "    return 1\n" ++
        "}\n" ++
        "do {\n" ++
        "    j()\n" ++
        "} while (a)\n" ++
        "throw new Error(\"e\")\n";

    const wanted = "import fs from \"node:fs\";\n" ++
        "const a = 1;\n" ++
        "let b = class {};\n" ++
        "export class D {}\n" ++
        "export default class E {}\n" ++
        "export function f() {}\n" ++
        "export { a };\n" ++
        "class C {\n" ++
        "    field = 1;\n" ++
        "    method() {}\n" ++
        "}\n" ++
        "function j() {\n" ++
        "    return 1;\n" ++
        "}\n" ++
        "do {\n" ++
        "    j();\n" ++
        "} while (a);\n" ++
        "throw new Error(\"e\");\n";

    try expect_formatted(source, wanted);
}

test "a parenthesis pair the reference re prints without is dropped" {
    const source = "const a = (b + c);\n" ++
        "f((d));\n" ++
        "const e = [(g)];\n" ++
        "h = (i);\n" ++
        "const j = { k: (l) };\n" ++
        "const m = ((n));\n" ++
        "throw (new Error(\"x\"));\n" ++
        "const o = p ? (q) : (r);\n";

    const wanted = "const a = b + c;\n" ++
        "f(d);\n" ++
        "const e = [g];\n" ++
        "h = i;\n" ++
        "const j = { k: l };\n" ++
        "const m = n;\n" ++
        "throw new Error(\"x\");\n" ++
        "const o = p ? q : r;\n";

    try expect_formatted(source, wanted);
}

test "a parenthesis pair the reference writes back is kept" {
    const source = "const a = (b, c);\n" ++
        "const d = (e = 1);\n" ++
        "const g = () => ({ h: 1 });\n" ++
        "const i = j ? (k ? 1 : 2) : 3;\n" ++
        "const l = (m + n) * o;\n" ++
        "const p = [...(q ?? [])];\n" ++
        "const r = (s) => (t ? 1 : 2);\n";

    try expect_formatted(source, source);
}

test "a statement ending on a dropped parenthesis still takes its separator" {
    try expect_formatted("const a = b ? c : (d || e)\n", "const a = b ? c : d || e;\n");
}

test "an in operator inside a for head keeps and gains the parentheses biome writes" {
    const source = "for (var i = 0, n = (\"x\" in o) ? 1 : 0; i < n; i++) {}\n" ++
        "for (x = (a in b); ; ) {}\n" ++
        "for (x = f(a in b); ; ) {}\n" ++
        "for (f(a in b).c in o) {}\n" ++
        "for (; a in b; ) {}\n" ++
        "for (x = function () {\n" ++
        "    return (a in b);\n" ++
        "}; ; ) {}\n" ++
        "const y = (a in b);\n";

    const wanted = "for (var i = 0, n = (\"x\" in o) ? 1 : 0; i < n; i++) {}\n" ++
        "for (x = (a in b); ; ) {}\n" ++
        "for (x = f((a in b)); ; ) {}\n" ++
        "for (f((a in b)).c in o) {\n" ++
        "}\n" ++
        "for (; a in b; ) {}\n" ++
        "for (\n" ++
        "    x = function () {\n" ++
        "        return a in b;\n" ++
        "    };\n" ++
        "    ;\n" ++
        ") {}\n" ++
        "const y = a in b;\n";

    try expect_formatted(source, wanted);
}

test "a bracket the source parted at one separator parts at every one" {
    const source = "const held = {\n" ++
        "    first: 1, second: 2,\n" ++
        "    third: 3,\n" ++
        "};\n";

    const wanted = "const held = {\n" ++
        "    first: 1,\n" ++
        "    second: 2,\n" ++
        "    third: 3,\n" ++
        "};\n";

    try expect_formatted(source, wanted);
}

test "a bracket the source wrote whole keeps the line it stands on" {
    const source = "const a = { first: 1, second: 2 };\n" ++
        "const b = [\n" ++
        "    \"x\", // a remark\n" ++
        "    \"y\",\n" ++
        "];\n";

    try expect_formatted(source, source);
}

test "a binaryish value an object operand of a logical run is a list the layout owns" {
    const source = "const a = info ?? { folder: undefined, repository: undefined, " ++
        "repositoryProps: undefined };\n";

    const wanted = "const a = info ?? {\n" ++
        "    folder: undefined,\n" ++
        "    repository: undefined,\n" ++
        "    repositoryProps: undefined,\n" ++
        "};\n";

    try expect_formatted(source, wanted);
}

test "a line comment never takes the token behind it onto its line" {
    const source = "function f() {\n" ++
        "    if (a || // note\n" ++
        "        !b\n" ++
        "    ) {\n" ++
        "        return;\n" ++
        "    }\n" ++
        "    g( // note\n" ++
        "        x);\n" ++
        "    const y = a || // note\n" ++
        "        b;\n" ++
        "}\n";

    const wanted = "function f() {\n" ++
        "    if (\n" ++
        "        a || // note\n" ++
        "        !b\n" ++
        "    ) {\n" ++
        "        return;\n" ++
        "    }\n" ++
        "    g(\n" ++
        "        // note\n" ++
        "        x,\n" ++
        "    );\n" ++
        "    const y =\n" ++
        "        a || // note\n" ++
        "        b;\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a block comment standing before a closing bracket keeps its line behind the comma" {
    const source = "var m = {\n" ++
        "    exports: {},\n" ++
        "    loaded: false\n" ++
        "    /* c */\n" ++
        "};\n" ++
        "var a = [\n" ++
        "    1,\n" ++
        "    2\n" ++
        "    /* c */\n" ++
        "];\n" ++
        "f(\n" ++
        "    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa,\n" ++
        "    bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n" ++
        "    /* c */\n" ++
        ");\n" ++
        "var b = [\n" ++
        "    1,\n" ++
        "    2,\n" ++
        "    /* c */\n" ++
        "];\n";

    const wanted = "var m = {\n" ++
        "    exports: {},\n" ++
        "    loaded: false,\n" ++
        "    /* c */\n" ++
        "};\n" ++
        "var a = [\n" ++
        "    1,\n" ++
        "    2,\n" ++
        "    /* c */\n" ++
        "];\n" ++
        "f(\n" ++
        "    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa,\n" ++
        "    bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb,\n" ++
        "    /* c */\n" ++
        ");\n" ++
        "var b = [\n" ++
        "    1,\n" ++
        "    2,\n" ++
        "    /* c */\n" ++
        "];\n";

    try expect_formatted(source, wanted);
}

test "a binary in a conditional that heads a header keeps a group of its own" {
    const source = "function a() {\n" ++
        "    function b() {\n" ++
        "        while (index--) {\n" ++
        "            if ((noCustomizer && data[2])\n" ++
        "                ? data[1] !== object[data[0]]\n" ++
        "                : !(data[0] in object)\n" ++
        "            ) {\n" ++
        "                return false;\n" ++
        "            }\n" ++
        "        }\n" ++
        "        if (type == \"number\"\n" ++
        "            ? (isArrayLike(object) && isIndex(index, object.length))\n" ++
        "            : (type == \"string\" && index in object)\n" ++
        "        ) {\n" ++
        "            return eq(object[index], value);\n" ++
        "        }\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "function a() {\n" ++
        "    function b() {\n" ++
        "        while (index--) {\n" ++
        "            if (\n" ++
        "                noCustomizer && data[2]\n" ++
        "                    ? data[1] !== object[data[0]]\n" ++
        "                    : !(data[0] in object)\n" ++
        "            ) {\n" ++
        "                return false;\n" ++
        "            }\n" ++
        "        }\n" ++
        "        if (\n" ++
        "            type == \"number\"\n" ++
        "                ? isArrayLike(object) && isIndex(index, object.length)\n" ++
        "                : type == \"string\" && index in object\n" ++
        "        ) {\n" ++
        "            return eq(object[index], value);\n" ++
        "        }\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a value the source broke from its equals sign joins it when the statement fits" {
    const source = "Firebug.Lite =\n" ++
        "{\n" ++
        "};\n" ++
        "Firebug.Lite.Style =\n" ++
        "[\n" ++
        "];\n" ++
        "var Lite =\n" ++
        "{\n" ++
        "};\n" ++
        "Lite =\n" ++
        "5;\n" ++
        "Lite =\n" ++
        "-1;\n";

    const wanted = "Firebug.Lite = {};\n" ++
        "Firebug.Lite.Style = [];\n" ++
        "var Lite = {};\n" ++
        "Lite = 5;\n" ++
        "Lite = -1;\n";

    try expect_formatted(source, wanted);
}

test "a chained assignment through a subscript breaks only at its last equals sign" {
    const source = "function g() {\n" ++
        "    function h() {\n" ++
        "        re = entityConversionRegexes[direction][name] = " ++
        "escapeEntitiesRegEx[direction](list);\n" ++
        "        re = entityConversionRegexes[direction].namexxxxx = " ++
        "escapeEntitiesRegEx[direction](list);\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "function g() {\n" ++
        "    function h() {\n" ++
        "        re = entityConversionRegexes[direction][name] =\n" ++
        "            escapeEntitiesRegEx[direction](list);\n" ++
        "        re = entityConversionRegexes[direction].namexxxxx =\n" ++
        "            escapeEntitiesRegEx[direction](list);\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a statement's parentheses move onto the function that heads its chain" {
    const source = ";(function() {\n" ++
        "  var x = 1;\n" ++
        "}.call(this));\n" ++
        "(function() {\n" ++
        "  var x = 1;\n" ++
        "}.call(this, 1));\n" ++
        "(class {\n" ++
        "  m() {}\n" ++
        "}.name);\n" ++
        "x = (function() {\n" ++
        "  var x = 1;\n" ++
        "}).call(this);\n" ++
        "((function() {\n" ++
        "  var x = 1;\n" ++
        "})).call(this);\n" ++
        "(function() {\n" ++
        "  var x = 1;\n" ++
        "}).call(this);\n";

    const wanted = "(function () {\n" ++
        "    var x = 1;\n" ++
        "}).call(this);\n" ++
        "(function () {\n" ++
        "    var x = 1;\n" ++
        "}).call(this, 1);\n" ++
        "(class {\n" ++
        "    m() {}\n" ++
        "}).name;\n" ++
        "x = function () {\n" ++
        "    var x = 1;\n" ++
        "}.call(this);\n" ++
        "(function () {\n" ++
        "    var x = 1;\n" ++
        "}).call(this);\n" ++
        "(function () {\n" ++
        "    var x = 1;\n" ++
        "}).call(this);\n";

    try expect_formatted(source, wanted);
}

test "an import list whose last name a comment trails parts like any list" {
    const source = "import {a, b\n" ++
        "// c\n" ++
        "} from \"x\";\n" ++
        "import {a, b\n" ++
        "/* c */} from \"x\";\n" ++
        "export {a, b // c\n" ++
        "} from \"x\";\n";

    const wanted = "import {\n" ++
        "    a,\n" ++
        "    b,\n" ++
        "    // c\n" ++
        "} from \"x\";\n" ++
        "import {\n" ++
        "    a,\n" ++
        "    b,\n" ++
        "    /* c */\n" ++
        "} from \"x\";\n" ++
        "export {\n" ++
        "    a,\n" ++
        "    b, // c\n" ++
        "} from \"x\";\n";

    try expect_formatted(source, wanted);
}

test "a pattern a standing comment closes breaks and keeps its brace spacing" {
    const source = "var {a, b\n" ++
        "// c\n" ++
        "} = x;\n" ++
        "var {a, b\n" ++
        "/* c */} = x;\n" ++
        "function f({a, b\n" ++
        "// c\n" ++
        "}) {}\n" ++
        "var {a, b /* c */} = x;\n";

    const wanted = "var {\n" ++
        "    a,\n" ++
        "    b,\n" ++
        "    // c\n" ++
        "} = x;\n" ++
        "var {\n" ++
        "    a,\n" ++
        "    b,\n" ++
        "    /* c */\n" ++
        "} = x;\n" ++
        "function f({\n" ++
        "    a,\n" ++
        "    b,\n" ++
        "    // c\n" ++
        "}) {}\n" ++
        "var { a, b /* c */ } = x;\n";

    try expect_formatted(source, wanted);
}

test "a block comment behind a case colon stays or moves where the reference puts it" {
    const source = "switch (a) {\n" ++
        "    case 1: /* c */\n" ++
        "    case 2: /* c */\n" ++
        "        f();\n" ++
        "    case 3: /* c */ g();\n" ++
        "    default: /* c */\n" ++
        "        h();\n" ++
        "}\n" ++
        "switch (a) { case 1: /* c */ }\n";

    const wanted = "switch (a) {\n" ++
        "    case 1: /* c */\n" ++
        "    case 2 /* c */:\n" ++
        "        f();\n" ++
        "    case 3:\n" ++
        "        /* c */ g();\n" ++
        "    default: /* c */\n" ++
        "        h();\n" ++
        "}\n" ++
        "switch (a) {\n" ++
        "    case 1: /* c */\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a comment behind a label colon moves before the colon or above the label" {
    const source = "foo: /* c */ for (;;) {}\n" ++
        "bar: // c\n" ++
        "for (;;) {}\n" ++
        "baz: /* c */\n" ++
        "/* d */\n" ++
        "while (x) {}\n";

    const wanted = "foo /* c */: for (;;) {}\n" ++
        "// c\n" ++
        "bar: for (;;) {}\n" ++
        "/* c */\n" ++
        "/* d */\n" ++
        "baz: while (x) {}\n";

    try expect_formatted(source, wanted);
}

test "a comment standing before a header's closing parenthesis keeps its line" {
    const source = "if (a\n" ++
        "// c\n" ++
        ") {}\n" ++
        "if (a\n" ++
        "/* c */) {}\n" ++
        "while (a &&\n" ++
        "    b\n" ++
        "    /* c */\n" ++
        ") {}\n";

    const wanted = "if (\n" ++
        "    a\n" ++
        "    // c\n" ++
        ") {\n" ++
        "}\n" ++
        "if (\n" ++
        "    a\n" ++
        "    /* c */\n" ++
        ") {\n" ++
        "}\n" ++
        "while (\n" ++
        "    a &&\n" ++
        "    b\n" ++
        "    /* c */\n" ++
        ") {}\n";

    try expect_formatted(source, wanted);
}

test "a comma falls between a same line comment and a standing one" {
    const source = "var m = {\n" ++
        "    a: 1,\n" ++
        "    b: false /* a */\n" ++
        "    /* b */\n" ++
        "};\n";

    const wanted = "var m = {\n" ++
        "    a: 1,\n" ++
        "    b: false /* a */,\n" ++
        "    /* b */\n" ++
        "};\n";

    try expect_formatted(source, wanted);
}

test "a comma that leads its line joins the line before it" {
    const source = "var express = require('../')\n" ++
        "  , request = require('supertest');\n" ++
        "\n" ++
        "a()\n" ++
        "  , b();\n" ++
        "\n" ++
        "x = (alpha\n" ++
        "  , beta);\n" ++
        "\n" ++
        "foo(alpha\n" ++
        "  , beta);\n" ++
        "\n" ++
        "let five = function () {\n" ++
        "  return 1;\n" ++
        "}\n" ++
        "  , six = 2;\n";

    const wanted = "var express = require(\"../\"),\n" ++
        "    request = require(\"supertest\");\n" ++
        "\n" ++
        "a(), b();\n" ++
        "\n" ++
        "x = (alpha, beta);\n" ++
        "\n" ++
        "foo(alpha, beta);\n" ++
        "\n" ++
        "let five = function () {\n" ++
        "        return 1;\n" ++
        "    },\n" ++
        "    six = 2;\n";

    try expect_formatted(source, wanted);
}

test "a comma that leads its line moves ahead of the comments before it" {
    const source = "var a1 = 1 /* x */ // y\n" ++
        "  , b1 = 2;\n" ++
        "\n" ++
        "var a2 = 1\n" ++
        "  /* own */\n" ++
        "  , b2 = 2;\n" ++
        "\n" ++
        "var a3 = 1 /* x */\n" ++
        "  // own\n" ++
        "  , b3 = 2;\n" ++
        "\n" ++
        "var a5 = 1 // x\n" ++
        "  , b5 = 2 // y\n" ++
        "  , c5 = 3;\n" ++
        "\n" ++
        "foo(alpha /* note */\n" ++
        "  , beta);\n" ++
        "\n" ++
        "foo(alpha // note\n" ++
        "  , beta);\n";

    const wanted = "var a1 = 1 /* x */, // y\n" ++
        "    b1 = 2;\n" ++
        "\n" ++
        "var a2 = 1,\n" ++
        "    /* own */\n" ++
        "    b2 = 2;\n" ++
        "\n" ++
        "var a3 = 1 /* x */,\n" ++
        "    // own\n" ++
        "    b3 = 2;\n" ++
        "\n" ++
        "var a5 = 1, // x\n" ++
        "    b5 = 2, // y\n" ++
        "    c5 = 3;\n" ++
        "\n" ++
        "foo(alpha /* note */, beta);\n" ++
        "\n" ++
        "foo(\n" ++
        "    alpha, // note\n" ++
        "    beta,\n" ++
        ");\n";

    try expect_formatted(source, wanted);
}

test "a block comment leading a declarator starts the declarator's line" {
    const source = "var a6 = 1, /* c */ b6 = 2;\n" ++
        "\n" ++
        "let a8, /* c */ b8;\n" ++
        "\n" ++
        "var a7 = 1\n" ++
        "  , // c\n" ++
        "  b7 = 2;\n";

    const wanted = "var a6 = 1,\n" ++
        "    /* c */ b6 = 2;\n" ++
        "\n" ++
        "let a8, /* c */ b8;\n" ++
        "\n" ++
        "var a7 = 1, // c\n" ++
        "    b7 = 2;\n";

    try expect_formatted(source, wanted);
}

test "a call's parenthesis and a subscript's bracket join the token before them" {
    const source = "foo\n" ++
        "  (bar);\n" ++
        "\n" ++
        "var x = list\n" ++
        "  [0];\n" ++
        "\n" ++
        "var y = obj.list\n" ++
        "  [index].name;\n" ++
        "\n" ++
        "function foo\n" ++
        "  (a) {}\n" ++
        "\n" ++
        "new Foo\n" ++
        "  (bar);\n" ++
        "\n" ++
        "foo /* c */ (bar);\n" ++
        "\n" ++
        "foo // c\n" ++
        "(bar);\n" ++
        "\n" ++
        "list /* c */ [0];\n" ++
        "\n" ++
        "const f = (x) => {\n" ++
        "  x()\n" ++
        "}\n" ++
        "\n" ++
        "[1, 2].forEach(f)\n";

    const wanted = "foo(bar);\n" ++
        "\n" ++
        "var x = list[0];\n" ++
        "\n" ++
        "var y = obj.list[index].name;\n" ++
        "\n" ++
        "function foo(a) {}\n" ++
        "\n" ++
        "new Foo(bar);\n" ++
        "\n" ++
        "foo(/* c */ bar);\n" ++
        "\n" ++
        "foo(\n" ++
        "    // c\n" ++
        "    bar,\n" ++
        ");\n" ++
        "\n" ++
        "list /* c */[0];\n" ++
        "\n" ++
        "const f = (x) => {\n" ++
        "    x();\n" ++
        "};\n" ++
        "\n" ++
        "[1, 2].forEach(f);\n";

    try expect_formatted(source, wanted);
}

test "a computed member after the head call starts a member chain group" {
    const source = "it(function (done) {\n" ++
        "    request(app)\n" ++
        "    [method]('/foo')\n" ++
        "      .expect(200, done)\n" ++
        "})\n" ++
        "\n" ++
        "it(function (done) {\n" ++
        "  request(app)\n" ++
        "  [method]('/')\n" ++
        "  .expect('ETag', 'W/\"c-IgR/L5SF7CJQff4wxKGF/vfPuZ0\"')\n" ++
        "  .expect(200, done);\n" ++
        "})\n" ++
        "\n" ++
        "someFactory()[someKey].bar().baz().qux().quux().corge()" ++
        ".grault().garply().waldo().fred();\n";

    const wanted = "it(function (done) {\n" ++
        "    request(app)[method](\"/foo\").expect(200, done);\n" ++
        "});\n" ++
        "\n" ++
        "it(function (done) {\n" ++
        "    request(app)\n" ++
        "        [method](\"/\")\n" ++
        "        .expect(\"ETag\", 'W/\"c-IgR/L5SF7CJQff4wxKGF/vfPuZ0\"')\n" ++
        "        .expect(200, done);\n" ++
        "});\n" ++
        "\n" ++
        "someFactory()\n" ++
        "    [someKey].bar()\n" ++
        "    .baz()\n" ++
        "    .qux()\n" ++
        "    .quux()\n" ++
        "    .corge()\n" ++
        "    .grault()\n" ++
        "    .garply()\n" ++
        "    .waldo()\n" ++
        "    .fred();\n";

    try expect_formatted(source, wanted);
}

test "a key the reference prints bare loses its quotes" {
    const source = "var o = {\n" ++
        "  \"char\u{f1}\": 1,\n" ++
        "  \"\u{3c0}\": 2,\n" ++
        "  \"\u{2160}\": 3,\n" ++
        "  \"a\u{200d}b\": 4,\n" ++
        "  \"1.23\": 5,\n" ++
        "  \"0.0000001\": 6,\n" ++
        "  \"1234567890123456\": 7,\n" ++
        "  \"12345678901234567\": 8,\n" ++
        "  \"01\": 9,\n" ++
        "  \"1e3\": 10,\n" ++
        "  \"1.0\": 11,\n" ++
        "  \".5\": 12,\n" ++
        "  \"1_000\": 13,\n" ++
        "  \"0x10\": 14,\n" ++
        "  \"\\u0041\": 15,\n" ++
        "  \"new\": 16,\n" ++
        "  \"9007199254740993\": 17,\n" ++
        "  \"100\": 18,\n" ++
        "  \"0\": 19,\n" ++
        "  \"1.5e300\": 20,\n" ++
        "};\n";

    const wanted = "var o = {\n" ++
        "    char\u{f1}: 1,\n" ++
        "    \u{3c0}: 2,\n" ++
        "    \u{2160}: 3,\n" ++
        "    a\u{200d}b: 4,\n" ++
        "    1.23: 5,\n" ++
        "    0.0000001: 6,\n" ++
        "    1234567890123456: 7,\n" ++
        "    \"12345678901234567\": 8,\n" ++
        "    \"01\": 9,\n" ++
        "    \"1e3\": 10,\n" ++
        "    \"1.0\": 11,\n" ++
        "    \".5\": 12,\n" ++
        "    \"1_000\": 13,\n" ++
        "    \"0x10\": 14,\n" ++
        "    \"\\u0041\": 15,\n" ++
        "    \"new\": 16,\n" ++
        "    \"9007199254740993\": 17,\n" ++
        "    100: 18,\n" ++
        "    0: 19,\n" ++
        "    \"1.5e300\": 20,\n" ++
        "};\n";

    try expect_formatted(source, wanted);
}

test "a key whose number overflows keeps its quotes" {
    const source = "var o = {\n" ++
        "    \"1e400\": 1,\n" ++
        "    raw: \"1e310\",\n" ++
        "    \"5e1_000\": 2,\n" ++
        "};\n";

    try expect_formatted(source, source);
}

test "a quoted class field key reads as the name it unquotes to" {
    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    const allocator = arena.allocator();
    const quoted_source = "class A {\n    'b' = 1;\n}\n";
    const bare_source = "class A {\n    b = 1;\n}\n";
    const dashed_source = "class A {\n    'b-c' = 1;\n}\n";
    const joined_source = "class A {\n    bc = 1;\n}\n";
    const quoted = try related(allocator, try held.kinds(allocator, quoted_source));
    const bare = try related(allocator, try held.kinds(allocator, bare_source));
    const dashed = try related(allocator, try held.kinds(allocator, dashed_source));
    const joined = try related(allocator, try held.kinds(allocator, joined_source));

    try std.testing.expect(terminated(quoted, bare));
    try std.testing.expect(!terminated(dashed, joined));
}

test "a parenthesised conditional arrow body loses its parentheses when it breaks" {
    const source = "const headersToObject = (thing) => (thing instanceof AxiosHeaders ? { " ++
        "...thing } : thing);\n" ++
        "const own = (obj, key) => (obj != null && utils.hasOwnProp(obj, key) ? obj[key] : " ++
        "undefined);\n" ++
        "const f = (a) => (a ? b : c);\n" ++
        "const callbackLookup = callbackify(lookup, (value) => (utils.isArray(value) ? value : " ++
        "[value]));\n";

    const wanted = "const headersToObject = (thing) =>\n" ++
        "    thing instanceof AxiosHeaders ? { ...thing } : thing;\n" ++
        "const own = (obj, key) =>\n" ++
        "    obj != null && utils.hasOwnProp(obj, key) ? obj[key] : undefined;\n" ++
        "const f = (a) => (a ? b : c);\n" ++
        "const callbackLookup = callbackify(lookup, (value) =>\n" ++
        "    utils.isArray(value) ? value : [value],\n" ++
        ");\n";

    try expect_formatted(source, wanted);
}

test "an exported binary breaks and indents like a statement" {
    const source = "export default isXHRAdapterSupported && function (config) {\n" ++
        "    return 1;\n" ++
        "};\n";

    const wanted = "export default isXHRAdapterSupported &&\n" ++
        "    function (config) {\n" ++
        "        return 1;\n" ++
        "    };\n";

    try expect_formatted(source, wanted);
}

test "an exported binary that overflows breaks at its operators" {
    const source = "export default someLongConditionNameNumberOne && " ++
        "someLongConditionNameNumberTwo && someOther;\n";

    const wanted = "export default someLongConditionNameNumberOne &&\n" ++
        "    someLongConditionNameNumberTwo &&\n" ++
        "    someOther;\n";

    try expect_formatted(source, wanted);
}

test "a template piece spelled as a colon is not a ternary colon" {
    const source = "const normalizedProtocol = rawProxyProtocol\n" ++
        "  ? rawProxyProtocol.includes(':')\n" ++
        "    ? rawProxyProtocol\n" ++
        "    : `${rawProxyProtocol}:`\n" ++
        "  : 'http:';\n";

    const wanted = "const normalizedProtocol = rawProxyProtocol\n" ++
        "    ? rawProxyProtocol.includes(\":\")\n" ++
        "        ? rawProxyProtocol\n" ++
        "        : `${rawProxyProtocol}:`\n" ++
        "    : \"http:\";\n";

    try expect_formatted(source, wanted);
}

test "an array element binary breaks after its operator when its operand must break" {
    const source = "const x = [\n" ++
        "  minified &&\n" ++
        "    terser({\n" ++
        "      maxWorkers: 1,\n" ++
        "    }),\n" ++
        "  a && function () { return 1; },\n" ++
        "  b + c,\n" ++
        "];\n";

    const wanted = "const x = [\n" ++
        "    minified &&\n" ++
        "        terser({\n" ++
        "            maxWorkers: 1,\n" ++
        "        }),\n" ++
        "    a &&\n" ++
        "        function () {\n" ++
        "            return 1;\n" ++
        "        },\n" ++
        "    b + c,\n" ++
        "];\n";

    try expect_formatted(source, wanted);
}

test "a line comment inside an arrow body binary keeps the body level" {
    const source = "const isBase64Char = (charCode) =>\n" ++
        "  (charCode >= 65 && charCode <= 90) || // A-Z\n" ++
        "  (charCode >= 97 && charCode <= 122) || // a-z\n" ++
        "  charCode === 95; // _ (base64url)\n";

    const wanted = "const isBase64Char = (charCode) =>\n" ++
        "    (charCode >= 65 && charCode <= 90) || // A-Z\n" ++
        "    (charCode >= 97 && charCode <= 122) || // a-z\n" ++
        "    charCode === 95; // _ (base64url)\n";

    try expect_formatted(source, wanted);
}

test "a broken callee arrow chain keeps its signatures level and breaks before its body" {
    const source = "const hasOwnProperty = (\n" ++
        "  ({ hasOwnProperty }) =>\n" ++
        "  (obj, prop) =>\n" ++
        "    hasOwnProperty.call(obj, prop)\n" ++
        ")(Object.prototype);\n";

    const wanted = "const hasOwnProperty = (\n" ++
        "    ({ hasOwnProperty }) =>\n" ++
        "    (obj, prop) =>\n" ++
        "        hasOwnProperty.call(obj, prop)\n" ++
        ")(Object.prototype);\n";

    try expect_formatted(source, wanted);
}

test "a broken callee arrow chain in a ternary branch breaks before its body" {
    const source = "const encodeText =\n" ++
        "  isFetchSupported &&\n" ++
        "  (typeof TextEncoder === 'function'\n" ++
        "    ? (\n" ++
        "        (encoder) => (str) =>\n" ++
        "          encoder.encode(str)\n" ++
        "      )(new TextEncoder())\n" ++
        "    : async (str) => new Uint8Array(await new Request(str).arrayBuffer()));\n";

    const wanted = "const encodeText =\n" ++
        "    isFetchSupported &&\n" ++
        "    (typeof TextEncoder === \"function\"\n" ++
        "        ? (\n" ++
        "              (encoder) => (str) =>\n" ++
        "                  encoder.encode(str)\n" ++
        "          )(new TextEncoder())\n" ++
        "        : async (str) => new Uint8Array(await new Request(str).arrayBuffer()));\n";

    try expect_formatted(source, wanted);
}

test "a declared assignment chain that must break puts each link on its own line" {
    const source = "const x = (a = b = {\n" ++
        "  k: 1 });\n";

    const wanted = "const x =\n" ++
        "    (a =\n" ++
        "    b =\n" ++
        "        {\n" ++
        "            k: 1,\n" ++
        "        });\n";

    try expect_formatted(source, wanted);
}

test "a broken assignment chain moves its tail value below the last link" {
    const source = "x = a = b = someVeryLongExpressionNameThatIsLong + " ++
        "anotherVeryLongExpressionNameHere + more;\n";

    const wanted = "x =\n" ++
        "    a =\n" ++
        "    b =\n" ++
        "        someVeryLongExpressionNameThatIsLong + " ++
        "anotherVeryLongExpressionNameHere + more;\n";

    try expect_formatted(source, wanted);
}

test "a parameter list with defaults is not an assignment chain" {
    const source = "const f = (a = 1, b = {\n" ++
        "  k: 1 }) => a;\n" ++
        "let y = (a = b = {});\n";

    const wanted = "const f = (\n" ++
        "    a = 1,\n" ++
        "    b = {\n" ++
        "        k: 1,\n" ++
        "    },\n" ++
        ") => a;\n" ++
        "let y = (a = b = {});\n";

    try expect_formatted(source, wanted);
}

test "a function element of an array loses its grouping parentheses" {
    const source = "var x = [\n" ++
        "/* 0 */\n" ++
        "/***/ (function(module, exports) {\n" ++
        "  return 1;\n" ++
        "/***/ }),\n" ++
        "/* 1 */\n" ++
        "/***/ (function(module, exports) {\n" ++
        "  return 2;\n" ++
        "/***/ })\n" ++
        "];\n";

    const wanted = "var x = [\n" ++
        "    /* 0 */\n" ++
        "    /***/ function (module, exports) {\n" ++
        "        return 1;\n" ++
        "        /***/\n" ++
        "    },\n" ++
        "    /* 1 */\n" ++
        "    /***/ function (module, exports) {\n" ++
        "        return 2;\n" ++
        "        /***/\n" ++
        "    },\n" ++
        "];\n";

    try expect_formatted(source, wanted);
}

test "a sequence element keeps only the parentheses it needs" {
    const source = "x = (a, (b ? c : d), e);\n" ++
        "y = (a, (b = 1), c);\n" ++
        "z = (a, (b, c));\n" ++
        "v = (a, (function () {}), b);\n";

    const wanted = "x = (a, b ? c : d, e);\n" ++
        "y = (a, (b = 1), c);\n" ++
        "z = (a, b, c);\n" ++
        "v = (a, function () {}, b);\n";

    try expect_formatted(source, wanted);
}

test "a labeled block holds statements and takes no trailing comma" {
    const source = "function f() {\n" ++
        "    a: {\n" ++
        "        b: {\n" ++
        "            let right;\n" ++
        "\n" ++
        "            if (x) {\n" ++
        "                y();\n" ++
        "            }\n" ++
        "        } // b\n" ++
        "\n" ++
        "        z();\n" ++
        "    } // a\n" ++
        "}\n";

    const wanted = "function f() {\n" ++
        "    a: {\n" ++
        "        b: {\n" ++
        "            let right;\n" ++
        "\n" ++
        "            if (x) {\n" ++
        "                y();\n" ++
        "            }\n" ++
        "        } // b\n" ++
        "\n" ++
        "        z();\n" ++
        "    } // a\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "an update operator abuts its operand" {
    const source = "++ v;\n" ++
        "a = ++ b;\n" ++
        "c = a + ++b;\n" ++
        "d = a ++ + b;\n" ++
        "-- x;\n" ++
        "x --;\n" ++
        "e = a - --b;\n" ++
        "f = a-- - b;\n" ++
        "g = a+ +b;\n" ++
        "h = a - -b;\n" ++
        "i = arr[ j ++ ];\n" ++
        "k = (m ++);\n" ++
        "foo(n ++, o --);\n";

    const wanted = "++v;\n" ++
        "a = ++b;\n" ++
        "c = a + ++b;\n" ++
        "d = a++ + b;\n" ++
        "--x;\n" ++
        "x--;\n" ++
        "e = a - --b;\n" ++
        "f = a-- - b;\n" ++
        "g = a + +b;\n" ++
        "h = a - -b;\n" ++
        "i = arr[j++];\n" ++
        "k = m++;\n" ++
        "foo(n++, o--);\n";

    try expect_formatted(source, wanted);
}

test "a comment alone in a parenthesized list takes no comma" {
    const source = "f(// c\n" ++
        ");\n" ++
        "function g(// c\n" ++
        ") {}\n" ++
        "h(\n" ++
        "    // only\n" ++
        ");\n" ++
        "const a = foo(/* x */);\n" ++
        "new K(/* renderer, object, camera, shadowCamera, geometry, d" ++
        "epthMaterial, group, more, more */);\n" ++
        "class Z { m( // c\n" ++
        ") {} }\n";

    const wanted = "f(\n" ++
        "    // c\n" ++
        ");\n" ++
        "function g(\n" ++
        "    // c\n" ++
        ") {}\n" ++
        "h(\n" ++
        "    // only\n" ++
        ");\n" ++
        "const a = foo(/* x */);\n" ++
        "new K(\n" ++
        "    /* renderer, object, camera, shadowCamera, geometry, dep" ++
        "thMaterial, group, more, more */\n" ++
        ");\n" ++
        "class Z {\n" ++
        "    m(\n" ++
        "        // c\n" ++
        "    ) {}\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a comment after a separator moves before it when the item ends there" {
    const source = "const o = {\n" ++
        "    a: 1, /* c */ /* d */\n" ++
        "    b: 2,\n" ++
        "};\n" ++
        "f(\n" ++
        "    a, /* c */ /* d */\n" ++
        "    b,\n" ++
        ");\n" ++
        "f(\n" ++
        "    a, /* c */\n" ++
        ");\n" ++
        "const q = [\n" ++
        "    1, /* c */ // d\n" ++
        "];\n";

    const wanted = "const o = {\n" ++
        "    a: 1 /* c */ /* d */,\n" ++
        "    b: 2,\n" ++
        "};\n" ++
        "f(a /* c */ /* d */, b);\n" ++
        "f(a /* c */);\n" ++
        "const q = [\n" ++
        "    1 /* c */, // d\n" ++
        "];\n";

    try expect_formatted(source, wanted);
}

test "a semicolon after a declaration is an empty statement and is dropped" {
    const source = "export function f() {}\n" ++
        ";\n" ++
        "export class C {}\n" ++
        ";\n" ++
        "export default function () {};\n" ++
        "let x = {};\n" ++
        "module.exports = {};\n";

    const wanted = "export function f() {}\n" ++
        "export class C {}\n" ++
        "export default function () {}\n" ++
        "let x = {};\n" ++
        "module.exports = {};\n";

    try expect_formatted(source, wanted);
}

test "a template hole measures without the blanks the printing drops" {
    const source = "function f() {\n" ++
        "    if (position !== undefined) {\n" ++
        "        for (let i = 1; i <= degree; i++) {\n" ++
        "            if (geometry.getAttribute(`sphericalHarmonics${ " ++
        "i }`).count !== position.count) {\n" ++
        "                throw new Error(\"x\");\n" ++
        "            }\n" ++
        "        }\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "function f() {\n" ++
        "    if (position !== undefined) {\n" ++
        "        for (let i = 1; i <= degree; i++) {\n" ++
        "            if (\n" ++
        "                geometry.getAttribute(`sphericalHarmonics${i" ++
        "}`).count !== position.count\n" ++
        "            ) {\n" ++
        "                throw new Error(\"x\");\n" ++
        "            }\n" ++
        "        }\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a comment trailing a sole parameter refuses the hug" {
    const source = "const f = ([a, b] /* c */) => {};\n" ++
        "function g([aaaaaaaaaaaaaaaaaaaaaaaa, bbbbbbbbbbbbbbbbbbbbbb" ++
        "bbbbbbbbbbb, cccccccccccccccccccccc] /* c */) {}\n" ++
        "function h({a, b\n" ++
        "// c\n" ++
        "}) {}\n";

    const wanted = "const f = ([a, b] /* c */) => {};\n" ++
        "function g(\n" ++
        "    [\n" ++
        "        aaaaaaaaaaaaaaaaaaaaaaaa,\n" ++
        "        bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb,\n" ++
        "        cccccccccccccccccccccc,\n" ++
        "    ] /* c */,\n" ++
        ") {}\n" ++
        "function h({\n" ++
        "    a,\n" ++
        "    b,\n" ++
        "    // c\n" ++
        "}) {}\n";

    try expect_formatted(source, wanted);
}

test "a jump argument after a lined comment keeps its parentheses" {
    const source = "function f() {\n" ++
        "    return (\n" ++
        "        // note\n" ++
        "        [\"a\", \"b\"].includes(x)\n" ++
        "    );\n" ++
        "}\n" ++
        "\n" ++
        "function g() {\n" ++
        "    return ( // note\n" ++
        "        a\n" ++
        "    );\n" ++
        "}\n" ++
        "\n" ++
        "function h() {\n" ++
        "    throw ( /* note */\n" ++
        "        new Error(x)\n" ++
        "    );\n" ++
        "}\n";

    const wanted = "function f() {\n" ++
        "    return (\n" ++
        "        // note\n" ++
        "        [\"a\", \"b\"].includes(x)\n" ++
        "    );\n" ++
        "}\n" ++
        "\n" ++
        "function g() {\n" ++
        "    return (\n" ++
        "        // note\n" ++
        "        a\n" ++
        "    );\n" ++
        "}\n" ++
        "\n" ++
        "function h() {\n" ++
        "    throw (\n" ++
        "        /* note */\n" ++
        "        new Error(x)\n" ++
        "    );\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a case test drops parentheses that span lines" {
    const source = "switch (true) {\n" ++
        "    case (a\n" ++
        "    && b):\n" ++
        "        break;\n" ++
        "}\n";

    const wanted = "switch (true) {\n" ++
        "    case a && b:\n" ++
        "        break;\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a statement that opens with a tag starts its own line" {
    const source = "x;\n" ++
        "// c\n" ++
        "<div>a</div>;\n" ++
        "<div />;\n" ++
        "/* d */\n" ++
        "<span />;\n" ++
        "if (a) {}\n" ++
        "<p />;\n";

    const wanted = "x;\n" ++
        "// c\n" ++
        "<div>a</div>;\n" ++
        "<div />;\n" ++
        "/* d */\n" ++
        "<span />;\n" ++
        "if (a) {\n" ++
        "}\n" ++
        "<p />;\n";

    try expect_formatted(source, wanted);
}

test "a line comment in a tag breaks the tag and keeps the token behind it" {
    const source = "<div\n" ++
        "  className=\"foo\" // comment\n" ++
        ">\n" ++
        "  {foo}\n" ++
        "</div>;\n" ++
        "<div // comment\n" ++
        "  id=\"foo\"\n" ++
        ">\n" ++
        "  {children}\n" ++
        "</div>;\n" ++
        "<br // comment\n" ++
        "/>;\n" ++
        "<img src=\"x\" /* c */ />;\n";

    const wanted = "<div\n" ++
        "    className=\"foo\" // comment\n" ++
        ">\n" ++
        "    {foo}\n" ++
        "</div>;\n" ++
        "<div // comment\n" ++
        "    id=\"foo\"\n" ++
        ">\n" ++
        "    {children}\n" ++
        "</div>;\n" ++
        "<br // comment\n" ++
        "/>;\n" ++
        "<img src=\"x\" /* c */ />;\n";

    try expect_formatted(source, wanted);
}

test "a hole holding a line comment breaks inside its braces" {
    const source = "<div>{a // c\n" ++
        "}</div>;\n" ++
        "<div>\n" ++
        "  {\n" ++
        "    // single line comment\n" ++
        "  }\n" ++
        "</div>;\n" ++
        "<div {...a // c\n" ++
        "} />;\n" ++
        "<div>{ // c\n" ++
        " <span/> }</div>;\n" ++
        "<div>\n" ++
        "  {\n" ++
        "    // a\n" ++
        "    /* b */\n" ++
        "    /* c */\n" ++
        "  }\n" ++
        "</div>;\n";

    const wanted = "<div>\n" ++
        "    {\n" ++
        "        a // c\n" ++
        "    }\n" ++
        "</div>;\n" ++
        "<div>\n" ++
        "    {\n" ++
        "        // single line comment\n" ++
        "    }\n" ++
        "</div>;\n" ++
        "<div\n" ++
        "    {\n" ++
        "        ...a // c\n" ++
        "    }\n" ++
        "/>;\n" ++
        "<div>\n" ++
        "    {\n" ++
        "        // c\n" ++
        "        <span />\n" ++
        "    }\n" ++
        "</div>;\n" ++
        "<div>\n" ++
        "    {\n" ++
        "        // a\n" ++
        "        /* b */\n" ++
        "        /* c */\n" ++
        "    }\n" ++
        "</div>;\n";

    try expect_formatted(source, wanted);
}

test "a conditional chain holding a tag writes its links on one line whatever the source broke" {
    const song = "thisIsASongAboutYourPoorSickPenguinHeHasAFeverAndHisToesAreBlue" ++
        "ButIfISingToYourPoorSickPenguinHeWillFeelBetterInADayOrTwo";

    const source = "cable ? \"satellite\" : isPublic ?\n" ++
        "    \"affairs\"\n" ++
        " : network ? <div><span>" ++ song ++ "</span></div> : \"dunno\";\n";

    const wanted = "cable ? (\n" ++
        "    \"satellite\"\n" ++
        ") : isPublic ? (\n" ++
        "    \"affairs\"\n" ++
        ") : network ? (\n" ++
        "    <div>\n" ++
        "        <span>\n" ++
        "            " ++ song ++ "\n" ++
        "        </span>\n" ++
        "    </div>\n" ++
        ") : (\n" ++
        "    \"dunno\"\n" ++
        ");\n";

    try expect_formatted(source, wanted);
}

test "an arrow whose body is a tag keeps its head beside the equals sign" {
    const contents = "props.even_looooooooooooooooooooooooooooooooooooooooooonger_contents";

    const parameters = "aaaaaaaaaaaaaaaaaaaaa, bbbbbbbbbbbbbbbbbbbbbbbbbbb, " ++
        "cccccccccccccccccccc, dddddddddd";

    const source = "const render = (props) => <div>{" ++ contents ++ "}</div>;\n" ++
        "const r = (" ++ parameters ++ ") => <div>{a}</div>;\n";

    const wanted = "const render = (props) => (\n" ++
        "    <div>{" ++ contents ++ "}</div>\n" ++
        ");\n" ++
        "const r = (\n" ++
        "    aaaaaaaaaaaaaaaaaaaaa,\n" ++
        "    bbbbbbbbbbbbbbbbbbbbbbbbbbb,\n" ++
        "    cccccccccccccccccccc,\n" ++
        "    dddddddddd,\n" ++
        ") => <div>{a}</div>;\n";

    try expect_formatted(source, wanted);
}

test "a comment in a tag's name or value keeps every token and settles" {
    try expect_settled("const a = < // c\ndiv />;\n");
    try expect_settled("const b = <// a\n// b\ndiv x=\"1\">\n  text\n</div>;\n");
    try expect_settled("<div\n  attr=\n  // comment\n  \"foo\"\n></div>;\n");
    try expect_settled("<div\n  attr= // comment\n  \"foo\"\n></div>;\n");
    try expect_settled("<div attr= /* c */ {x} b=\"1\" />;\n");
    try expect_settled("<div\n  attr=\n  /* comment */\n  \"foo\"\n></div>;\n");
}

test "a pattern holding a nested pattern breaks its properties" {
    const source = "const { a: { b } } = x;\n" ++
        "const { a: [b] } = x;\n" ++
        "const { a: { b } = {} } = x;\n" ++
        "({ a: { b } = {} } = x);\n" ++
        "for (const { a: { b } } of x) {}\n" ++
        "function f({ a: { b: { c } } }) {}\n" ++
        "function g(x, { a: { b } }) {}\n" ++
        "try {} catch ({ a: { b } }) {}\n" ++
        "const [{ a: { b } }] = x;\n" ++
        "f(({ a: { b } } = x));\n";

    const wanted = "const {\n" ++
        "    a: { b },\n" ++
        "} = x;\n" ++
        "const {\n" ++
        "    a: [b],\n" ++
        "} = x;\n" ++
        "const { a: { b } = {} } = x;\n" ++
        "({\n" ++
        "    a: { b } = {},\n" ++
        "} = x);\n" ++
        "for (const {\n" ++
        "    a: { b },\n" ++
        "} of x) {\n" ++
        "}\n" ++
        "function f({\n" ++
        "    a: {\n" ++
        "        b: { c },\n" ++
        "    },\n" ++
        "}) {}\n" ++
        "function g(x, { a: { b } }) {}\n" ++
        "try {\n" ++
        "} catch ({ a: { b } }) {}\n" ++
        "const [\n" ++
        "    {\n" ++
        "        a: { b },\n" ++
        "    },\n" ++
        "] = x;\n" ++
        "f(\n" ++
        "    ({\n" ++
        "        a: { b },\n" ++
        "    } = x),\n" ++
        ");\n";

    try expect_formatted(source, wanted);
}

test "a closing brace after an empty object takes its space" {
    const source = "const {a = {}} = src;\n" ++
        "const {style: {color = c} = {}} = src;\n" ++
        "x = {a: {b: {}}};\n" ++
        "const j = `${{a: 1}}`;\n";

    const wanted = "const { a = {} } = src;\n" ++
        "const { style: { color = c } = {} } = src;\n" ++
        "x = { a: { b: {} } };\n" ++
        "const j = `${{ a: 1 }}`;\n";

    try expect_formatted(source, wanted);
}

test "a yield operand and a spread argument keep the parentheses biome writes" {
    const source = "function* k() {\n" ++
        "    x = (yield a) + 1;\n" ++
        "    z = (yield a) ? b : c;\n" ++
        "    w = (yield a) || b;\n" ++
        "    m = [...(yield)];\n" ++
        "    h(...yield a);\n" ++
        "}\n" ++
        "async function n() {\n" ++
        "    h(...await a);\n" ++
        "}\n" ++
        "x = [...a || b];\n" ++
        "y = { ...a + b };\n" ++
        "f(...a instanceof B);\n";

    const wanted = "function* k() {\n" ++
        "    x = (yield a) + 1;\n" ++
        "    z = (yield a) ? b : c;\n" ++
        "    w = (yield a) || b;\n" ++
        "    m = [...(yield)];\n" ++
        "    h(...(yield a));\n" ++
        "}\n" ++
        "async function n() {\n" ++
        "    h(...(await a));\n" ++
        "}\n" ++
        "x = [...(a || b)];\n" ++
        "y = { ...(a + b) };\n" ++
        "f(...(a instanceof B));\n";

    try expect_formatted(source, wanted);
}

test "an optional chain under a plain link keeps its parentheses" {
    const source = "x = (a?.b).c;\n" ++
        "x = (a?.b)();\n" ++
        "x = (a?.b.c).d;\n" ++
        "x = (a?.())();\n" ++
        "x = (a?.[b]).c;\n" ++
        "new (a?.b)();\n" ++
        "x = (a?.b)?.c;\n" ++
        "x = (a?.b)?.();\n" ++
        "x = y[(a?.b)];\n" ++
        "x = f((a?.b));\n";

    const wanted = "x = (a?.b).c;\n" ++
        "x = (a?.b)();\n" ++
        "x = (a?.b.c).d;\n" ++
        "x = (a?.())();\n" ++
        "x = (a?.[b]).c;\n" ++
        "new (a?.b)();\n" ++
        "x = a?.b?.c;\n" ++
        "x = a?.b?.();\n" ++
        "x = y[(a?.b)];\n" ++
        "x = f(a?.b);\n";

    try expect_formatted(source, wanted);
}

test "a parenthesis three links under a template hole stays where biome keeps it" {
    const source = "x = `${(a).b}`;\n" ++
        "x = `${(a).b()}`;\n" ++
        "x = `${[(a)]}`;\n" ++
        "x = `${f((a))}`;\n" ++
        "x = `${a + (b) + c}`;\n" ++
        "x = `${(a)}`;\n" ++
        "x = `${{ a: (b) }}`;\n" ++
        "x = `${typeof (a).b}`;\n" ++
        "x = `${(a) ? b : c}`;\n" ++
        "x = `${new (a)().b}`;\n" ++
        "x = `${((a)).b()}`;\n";

    const wanted = "x = `${a.b}`;\n" ++
        "x = `${(a).b()}`;\n" ++
        "x = `${[(a)]}`;\n" ++
        "x = `${f(a)}`;\n" ++
        "x = `${a + (b) + c}`;\n" ++
        "x = `${a}`;\n" ++
        "x = `${{ a: b }}`;\n" ++
        "x = `${typeof (a).b}`;\n" ++
        "x = `${a ? b : c}`;\n" ++
        "x = `${new (a)().b}`;\n" ++
        "x = `${(a).b()}`;\n";

    try expect_formatted(source, wanted);
}

test "a space between two holes is text that keeps them on one line" {
    const source = "function f() {\n" ++
        "    return (\n" ++
        "        <div class=\"profile\">\n" ++
        "            <h2>{user.name.first} {user.name.last}</h2>\n" ++
        "            <h2>\n" ++
        "                {a} {b}\n" ++
        "            </h2>\n" ++
        "        </div>\n" ++
        "    );\n" ++
        "}\n" ++
        "spaces = <div>   </div>;\n" ++
        "w = <Message>\n" ++
        "    <Tag />\n" ++
        "\n" ++
        "    <Tag />\n" ++
        "</Message >;\n";

    const wanted = "function f() {\n" ++
        "    return (\n" ++
        "        <div class=\"profile\">\n" ++
        "            <h2>\n" ++
        "                {user.name.first} {user.name.last}\n" ++
        "            </h2>\n" ++
        "            <h2>\n" ++
        "                {a} {b}\n" ++
        "            </h2>\n" ++
        "        </div>\n" ++
        "    );\n" ++
        "}\n" ++
        "spaces = <div> </div>;\n" ++
        "w = (\n" ++
        "    <Message>\n" ++
        "        <Tag />\n" ++
        "\n" ++
        "        <Tag />\n" ++
        "    </Message>\n" ++
        ");\n";

    try expect_formatted(source, wanted);
}

test "a logical operand the source broke keeps the indent its first printing gave it" {
    const source = "function a() {\n" ++
        "    if (x) {\n" ++
        "        i(e,{instancePath:t,parentData:n,parentDataProperty:r," ++
        "rootData:o})||bar(null===s?i.errors:s.concat(i.errors),s.length),c=a===l,f=f||c;\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "function a() {\n" ++
        "    if (x) {\n" ++
        "        i(e, { instancePath: t, parentData: n, parentDataProperty: r, rootData: o }) " ++
        "||\n" ++
        "            bar(null === s ? i.errors : s.concat(i.errors), s.length),\n" ++
        "            (c = a === l),\n" ++
        "            (f = f || c);\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "a parenthesized sequence in a logical operand parts at its comma" {
    const source = "function a() {\n" ++
        "    if (a) {\n" ++
        "        if (b) {\n" ++
        "            if (c) {\n" ++
        "                if (d) {\n" ++
        "                    const u = i;\n" ++
        "                    j(n,{instancePath:t+\"/buildHttp\",parentData:e," ++
        "parentDataProperty:\"buildHttp\"," ++
        "rootData:o})||(s=null===s?j.errors:s.concat(j.errors),i=s.length);\n" ++
        "                }\n" ++
        "            }\n" ++
        "        }\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "function a() {\n" ++
        "    if (a) {\n" ++
        "        if (b) {\n" ++
        "            if (c) {\n" ++
        "                if (d) {\n" ++
        "                    const u = i;\n" ++
        "                    j(n, {\n" ++
        "                        instancePath: t + \"/buildHttp\",\n" ++
        "                        parentData: e,\n" ++
        "                        parentDataProperty: \"buildHttp\",\n" ++
        "                        rootData: o,\n" ++
        "                    }) ||\n" ++
        "                        ((s = null === s ? j.errors : s.concat(j.errors)),\n" ++
        "                        (i = s.length));\n" ++
        "                }\n" ++
        "            }\n" ++
        "        }\n" ++
        "    }\n" ++
        "}\n";

    const settled = "function a() {\n" ++
        "    if (a) {\n" ++
        "        if (b) {\n" ++
        "            if (c) {\n" ++
        "                const a = i;\n" ++
        "                O(r, {\n" ++
        "                    instancePath: t + \"/\" + n.replace(/~/g, \"~0\").replace(/\\//g, " ++
        "\"~1\"),\n" ++
        "                    parentData: e,\n" ++
        "                    parentDataProperty: n,\n" ++
        "                    rootData: o,\n" ++
        "                }) ||\n" ++
        "                    ((s = null === s ? O.errors : s.concat(O.errors)), (i = " ++
        "s.length)),\n" ++
        "                    (p = a === i),\n" ++
        "                    (c = c || p);\n" ++
        "            }\n" ++
        "        }\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
    try expect_formatted(settled, settled);
}

test "a curried arrow closing an object before its trailing comma closes its chain" {
    const source = "const o = {\n" ++
        "    create: () => (source) => ({ of: source.length }),\n" ++
        "};\n" ++
        "const T = [\n" ++
        "    {\n" ++
        "        create: () => (s) => [s],\n" ++
        "    },\n" ++
        "];\n" ++
        "const a = {\n" ++
        "    b: {\n" ++
        "        create: (x) => (s) => ({}),\n" ++
        "    },\n" ++
        "};\n";

    try expect_formatted(source, source);
}

test "a template hole written on its own lines takes no comma" {
    const source = "x = `|${\n" ++
        "    b || \"\"\n" ++
        "}|`;\n" ++
        "f(`|${\n" ++
        "    b\n" ++
        "}|`);\n";

    const wanted = "x = `|${b || \"\"}|`;\n" ++
        "f(`|${b}|`);\n";

    try expect_formatted(source, wanted);
}

test "a type cast paren around a hugged arrow takes no comma and settles" {
    try expect_settled("it(\"x\", () => {\n" ++
        "    expect(() =>\n" ++
        "        multiItemCache.get(\n" ++
        "            /** @type {EXPECTED_ANY} */ (\n" ++
        "                (/** @type {unknown} */ _) => /** @type {() => unknown} */ (_)()\n" ++
        "            )\n" ++
        "        )\n" ++
        "    ).toThrow(TypeError);\n" ++
        "});\n");
}

test "a type cast paren keeps the comments that open it inside" {
    const source = "x = /** @type {A} */ (\n" ++
        "    /* c */ value\n" ++
        ");\n" ++
        "const { start, end } = /** @type {Positioned} */ (\n" ++
        "    /** @type {unknown} */ (value)\n" ++
        ");\n" ++
        "y = /** @type {A} */ (\n" ++
        "    // c\n" ++
        "    value\n" ++
        ");\n";

    const wanted = "x = /** @type {A} */ (/* c */ value);\n" ++
        "const { start, end } = /** @type {Positioned} */ " ++
        "(/** @type {unknown} */ (value));\n" ++
        "y = /** @type {A} */ (\n" ++
        "    // c\n" ++
        "    value\n" ++
        ");\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "a paren that opens with a type cast keeps its place in front of the cast" {
    const source = "if (\n" ++
        "    !a ||\n" ++
        "    !(\n" ++
        "        /** @type {string} */ (value.string).startsWith(\"file://\")\n" ++
        "    ) ||\n" ++
        "    b\n" ++
        ") {\n" ++
        "}\n" ++
        "x = typeof (\n" ++
        "    /** @type {{ then?: unknown }} */ (result).then\n" ++
        ");\n";

    const wanted = "if (!a || !(/** @type {string} */ (value.string).startsWith(\"file://\")) " ++
        "|| b) {\n" ++
        "}\n" ++
        "x = typeof (/** @type {{ then?: unknown }} */ (result).then);\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "a trailing comma gives a require call no second argument" {
    const wanted = "function testCase(number) {\n" ++
        "    expect(\n" ++
        "        require(\n" ++
        "            number === 1\n" ++
        "                ? \"./folder/file1\"\n" ++
        "                : number === 2\n" ++
        "                  ? \"./folder/file2\"\n" ++
        "                  : number === 3\n" ++
        "                    ? \"./folder/file3\"\n" ++
        "                    : \"./missingModule\",\n" ++
        "        ),\n" ++
        "    ).toBe(\"file\" + number);\n" ++
        "}\n";

    try expect_formatted(wanted, wanted);
}

test "a comment on its own line after a broken property value sits at the property's level" {
    const source = "y = {\n" ++
        "    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:\n" ++
        "        bbbbbbbbbbbbbbbbbbbbbbbbbbbbb && cccccccccccccccccccccccccccc " ++
        "? ddddddddddddddddd : e\n" ++
        "    // c\n" ++
        "};\n";

    const wanted = "y = {\n" ++
        "    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:\n" ++
        "        bbbbbbbbbbbbbbbbbbbbbbbbbbbbb && cccccccccccccccccccccccccccc\n" ++
        "            ? ddddddddddddddddd\n" ++
        "            : e,\n" ++
        "    // c\n" ++
        "};\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "a comment on its own line after an arrow sits at its body's level" {
    const source = "const g = (group) =>\n" ++
        "\t// c\n" ++
        "\tfoo(bar);\n" ++
        "const i = (group) =>\n" ++
        "\t/* c */\n" ++
        "\t({\n" ++
        "\t\ta: 1\n" ++
        "\t});\n";

    const wanted = "const g = (group) =>\n" ++
        "    // c\n" ++
        "    foo(bar);\n" ++
        "const i = (group) =>\n" ++
        "    /* c */\n" ++
        "    ({\n" ++
        "        a: 1,\n" ++
        "    });\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "a dynamic import after a property colon keeps its value group closed" {
    const source = "x = {\n" ++
        "  embeddedEditorComponent: import('../../editor/index')" ++
        ".then((c) => c.EmbeddedEditorxxxxx),\n" ++
        "};\n" ++
        "y = {\n" ++
        "  e: import('../../editor/index/cccccccccccccccccccccccccccccccc')" ++
        ".then(c).then(d).then(e),\n" ++
        "};\n";

    const wanted = "x = {\n" ++
        "    embeddedEditorComponent: import(\"../../editor/index\").then(\n" ++
        "        (c) => c.EmbeddedEditorxxxxx,\n" ++
        "    ),\n" ++
        "};\n" ++
        "y = {\n" ++
        "    e: import(\"../../editor/index/cccccccccccccccccccccccccccccccc\")\n" ++
        "        .then(c)\n" ++
        "        .then(d)\n" ++
        "        .then(e),\n" ++
        "};\n";

    try expect_formatted(source, wanted);
}

test "an arrow called where it is valued keeps its parentheses tight" {
    const source = "dd = /* c */ (() =>\n" ++
        "  typeof document === 'undefined' ? null : document.documentElementxxxxxxxxx" ++
        "xxxxxxxxxxxx)();\n" ++
        "dd = (async () =>\n" ++
        "  await aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa(bbbbbbbbbbbbbbb" ++
        "bbbbbbbbbbb))();\n";

    const wanted = "dd = /* c */ (() =>\n" ++
        "    typeof document === \"undefined\"\n" ++
        "        ? null\n" ++
        "        : document.documentElementxxxxxxxxxxxxxxxxxxxxx)();\n" ++
        "dd = (async () =>\n" ++
        "    await aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa(\n" ++
        "        bbbbbbbbbbbbbbbbbbbbbbbbbb,\n" ++
        "    ))();\n";

    try expect_formatted(source, wanted);
}

test "a class extending a member named default keeps its class body" {
    const source = "var Oj = class extends Lct.default {\n" ++
        "    a(e, r) {\n" ++
        "        b;\n" ++
        "    }\n" ++
        "    c() {}\n" ++
        "};\n" ++
        "export default {\n" ++
        "    a() {},\n" ++
        "    c() {},\n" ++
        "};\n";

    const wanted = "var Oj = class extends Lct.default {\n" ++
        "    a(e, r) {\n" ++
        "        b;\n" ++
        "    }\n" ++
        "    c() {}\n" ++
        "};\n" ++
        "export default {\n" ++
        "    a() {},\n" ++
        "    c() {},\n" ++
        "};\n";

    try expect_formatted(source, wanted);
}

test "a call on a member named like a keyword lists its arguments" {
    const source_a = "Notification.createError('failure').do(\n" ++
        "  () => {},\n" ++
        "  (error) => events.push(['do', error])\n" ++
        ");\n" ++
        "gen.return(\n" ++
        "  x,\n" ++
        "  y\n" ++
        ");\n" ++
        "a?.throw(\n" ++
        "  x,\n" ++
        "  y\n" ++
        ");\n" ++
        "switch (a.case(\n" ++
        "  x,\n" ++
        "  y\n" ++
        ")) {\n" ++
        "}\n";

    const wanted_a = "Notification.createError(\"failure\").do(\n" ++
        "    () => {},\n" ++
        "    (error) => events.push([\"do\", error]),\n" ++
        ");\n" ++
        "gen.return(x, y);\n" ++
        "a?.throw(x, y);\n" ++
        "switch (a.case(x, y)) {\n" ++
        "}\n";

    const source_b = "class Q {\n" ++
        "  do(\n" ++
        "    a,\n" ++
        "    b\n" ++
        "  ) {\n" ++
        "    return a;\n" ++
        "  }\n" ++
        "}\n" ++
        "const o = {\n" ++
        "  x,\n" ++
        "  throw(\n" ++
        "    a,\n" ++
        "    b\n" ++
        "  ) {\n" ++
        "    return a;\n" ++
        "  },\n" ++
        "};\n";

    const wanted_b = "class Q {\n" ++
        "    do(a, b) {\n" ++
        "        return a;\n" ++
        "    }\n" ++
        "}\n" ++
        "const o = {\n" ++
        "    x,\n" ++
        "    throw(a, b) {\n" ++
        "        return a;\n" ++
        "    },\n" ++
        "};\n";

    try expect_formatted(source_a, wanted_a);
    try expect_formatted(source_b, wanted_b);
    try expect_formatted(wanted_a, wanted_a);
    try expect_formatted(wanted_b, wanted_b);
}

test "a declarator list measures an object written without spaces at its printed width" {
    const source = "function T(a){if(x){if(y){if(z){l=!1;}for(var " ++
        "w={b:8,t:9,n:10,v:11,f:12,r:13},r=[],m=0,c=a.length;m<c;++m){p=a[m];}}}}\n";

    const wanted = "function T(a) {\n" ++
        "    if (x) {\n" ++
        "        if (y) {\n" ++
        "            if (z) {\n" ++
        "                l = !1;\n" ++
        "            }\n" ++
        "            for (\n" ++
        "                var w = { b: 8, t: 9, n: 10, v: 11, f: 12, r: 13 },\n" ++
        "                    r = [],\n" ++
        "                    m = 0,\n" ++
        "                    c = a.length;\n" ++
        "                m < c;\n" ++
        "                ++m\n" ++
        "            ) {\n" ++
        "                p = a[m];\n" ++
        "            }\n" ++
        "        }\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "an own-line comment after a list's last arrow stays outside the arrow's body" {
    const source_a = "__webpack_require__.d(__webpack_exports__, {\n" ++
        "/* harmony export */   parse: () => (/* binding */ parse)\n" ++
        "/* harmony export */ });\n";

    const wanted_a = "__webpack_require__.d(__webpack_exports__, {\n" ++
        "    /* harmony export */ parse: () => /* binding */ parse,\n" ++
        "    /* harmony export */\n" ++
        "});\n";

    const source_b = "const o = {\n" ++
        "   parse: () => a + b\n" ++
        "   /* c */\n" ++
        "};\n" ++
        "const p = {\n" ++
        "   parse: () => call(a, b)\n" ++
        "   /* c */\n" ++
        "};\n";

    const wanted_b = "const o = {\n" ++
        "    parse: () => a + b,\n" ++
        "    /* c */\n" ++
        "};\n" ++
        "const p = {\n" ++
        "    parse: () => call(a, b),\n" ++
        "    /* c */\n" ++
        "};\n";

    const source_c = "f(a, () => x\n" ++
        "/* c */);\n" ++
        "const a = [b, () => x\n" ++
        "/* c */];\n";

    const wanted_c = "f(\n" ++
        "    a,\n" ++
        "    () => x,\n" ++
        "    /* c */\n" ++
        ");\n" ++
        "const a = [\n" ++
        "    b,\n" ++
        "    () => x,\n" ++
        "    /* c */\n" ++
        "];\n";

    try expect_formatted(source_a, wanted_a);
    try expect_formatted(source_b, wanted_b);
    try expect_formatted(source_c, wanted_c);
    try expect_formatted(wanted_a, wanted_a);
    try expect_formatted(wanted_b, wanted_b);
    try expect_formatted(wanted_c, wanted_c);
}

test "a method named like a keyword formats as a method" {
    const source_a = "const o = {\n" ++
        "  x,\n" ++
        "  for(\n" ++
        "    a,\n" ++
        "    b\n" ++
        "  ) {\n" ++
        "    return a;\n" ++
        "  },\n" ++
        "  as(\n" ++
        "    a,\n" ++
        "    b\n" ++
        "  ) {\n" ++
        "    return a;\n" ++
        "  },\n" ++
        "};\n" ++
        "const q = [{ if(\n" ++
        "  a,\n" ++
        "  b\n" ++
        ") {} }];\n";

    const wanted_a = "const o = {\n" ++
        "    x,\n" ++
        "    for(a, b) {\n" ++
        "        return a;\n" ++
        "    },\n" ++
        "    as(a, b) {\n" ++
        "        return a;\n" ++
        "    },\n" ++
        "};\n" ++
        "const q = [{ if(a, b) {} }];\n";

    const source_b = "class Q {\n" ++
        "  as(\n" ++
        "    a,\n" ++
        "    b\n" ++
        "  ) {\n" ++
        "    return a;\n" ++
        "  }\n" ++
        "  require(\n" ++
        "    a,\n" ++
        "    b\n" ++
        "  ) {\n" ++
        "    return a;\n" ++
        "  }\n" ++
        "}\n" ++
        "a.require(\n" ++
        "  x,\n" ++
        "  y\n" ++
        ");\n";

    const wanted_b = "class Q {\n" ++
        "    as(a, b) {\n" ++
        "        return a;\n" ++
        "    }\n" ++
        "    require(a, b) {\n" ++
        "        return a;\n" ++
        "    }\n" ++
        "}\n" ++
        "a.require(x, y);\n";

    try expect_formatted(source_a, wanted_a);
    try expect_formatted(source_b, wanted_b);
    try expect_formatted(wanted_a, wanted_a);
    try expect_formatted(wanted_b, wanted_b);
}

test "a while after a block that is not a do body starts its own statement" {
    const source = "function f() { if (a) { x(); } while (b) { y(); } }\n" ++
        "function g() { for (;;) { x(); } while (b) { y(); } }\n" ++
        "function h() { do { x(); } while (a); while (b) { y(); } }\n";

    const wanted = "function f() {\n" ++
        "    if (a) {\n" ++
        "        x();\n" ++
        "    }\n" ++
        "    while (b) {\n" ++
        "        y();\n" ++
        "    }\n" ++
        "}\n" ++
        "function g() {\n" ++
        "    for (;;) {\n" ++
        "        x();\n" ++
        "    }\n" ++
        "    while (b) {\n" ++
        "        y();\n" ++
        "    }\n" ++
        "}\n" ++
        "function h() {\n" ++
        "    do {\n" ++
        "        x();\n" ++
        "    } while (a);\n" ++
        "    while (b) {\n" ++
        "        y();\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "an assigned sequence callee breaks inside its parentheses" {
    const source_a = "function f6() {\n" ++
        "function f5() {\n" ++
        "function f4() {\n" ++
        "function f3() {\n" ++
        "function f2() {\n" ++
        "function f1() {\n" ++
        "function f0() {\n" ++
        "const subtype =\n" ++
        "  (0,_helpers_js__WEBPACK_IMPORTED_MODULE_1__.return_type)(tokeniser, " ++
        "typeName) ||\n" ++
        "  tokeniser.error(\"Missing Promise subtype\");\n" ++
        "ret.subtype.push(subtype);\n" ++
        "}\n" ++
        "}\n" ++
        "}\n" ++
        "}\n" ++
        "}\n" ++
        "}\n" ++
        "}\n";

    const wanted_a = "function f6() {\n" ++
        "    function f5() {\n" ++
        "        function f4() {\n" ++
        "            function f3() {\n" ++
        "                function f2() {\n" ++
        "                    function f1() {\n" ++
        "                        function f0() {\n" ++
        "                            const subtype =\n" ++
        "                                (0,\n" ++
        "                                _helpers_js__WEBPACK_IMPORTED_MODULE_1__.r" ++
        "eturn_type)(\n" ++
        "                                    tokeniser,\n" ++
        "                                    typeName,\n" ++
        "                                ) || tokeniser.error(\"Missing Promise " ++
        "subtype\");\n" ++
        "                            ret.subtype.push(subtype);\n" ++
        "                        }\n" ++
        "                    }\n" ++
        "                }\n" ++
        "            }\n" ++
        "        }\n" ++
        "    }\n" ++
        "}\n";

    const source_b = "function f0() {\n" ++
        "    subtype = (0,_helpers_js__WEBPACK_IMPORTED_MODULE_1__.return_typexxxxx" ++
        "xxxxxxxxxxxxxxxxxxxx)(tokeniser, typeName);\n" ++
        "}\n";

    const wanted_b = "function f0() {\n" ++
        "    subtype = (0,\n" ++
        "    _helpers_js__WEBPACK_IMPORTED_MODULE_1__.return_typexxxxxxxxxxxxxxxxxx" ++
        "xxxxxxx)(\n" ++
        "        tokeniser,\n" ++
        "        typeName,\n" ++
        "    );\n" ++
        "}\n";

    try expect_formatted(source_a, wanted_a);
    try expect_formatted(source_b, wanted_b);
    try expect_formatted(wanted_a, wanted_a);
    try expect_formatted(wanted_b, wanted_b);
}

test "a block after a label is a statement body" {
    const source_a = "function f(){a:{b:{c=1;d=2;if(x){y()}}}}\n";

    const wanted_a = "function f() {\n" ++
        "    a: {\n" ++
        "        b: {\n" ++
        "            c = 1;\n" ++
        "            d = 2;\n" ++
        "            if (x) {\n" ++
        "                y();\n" ++
        "            }\n" ++
        "        }\n" ++
        "    }\n" ++
        "}\n";

    const source_b = "function g(){if(a){x()}while(1){y()}b:{c:{d=1;e=2}}}\n";

    const wanted_b = "function g() {\n" ++
        "    if (a) {\n" ++
        "        x();\n" ++
        "    }\n" ++
        "    while (1) {\n" ++
        "        y();\n" ++
        "    }\n" ++
        "    b: {\n" ++
        "        c: {\n" ++
        "            d = 1;\n" ++
        "            e = 2;\n" ++
        "        }\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source_a, wanted_a);
    try expect_formatted(source_b, wanted_b);
    try expect_formatted(wanted_a, wanted_a);
    try expect_formatted(wanted_b, wanted_b);
}

test "a binary after a broken sequence callee keeps its operand on the operator's line" {
    const source = "function f6() {\n" ++
        "    function f5() {\n" ++
        "        function f4() {\n" ++
        "            function f3() {\n" ++
        "                function f2() {\n" ++
        "                    function f1() {\n" ++
        "                        function f0() {\n" ++
        "                            const subtype =\n" ++
        "                                (0,\n" ++
        "                                _helpers_js__WEBPACK_IMPORTED_MODULE_1__.typ" ++
        "e_with_extended_attributes)(\n" ++
        "                                    tokeniser,\n" ++
        "                                    typeName,\n" ++
        "                                ) || tokeniser.error(`Missing ${base.value} " ++
        "subtype`);\n" ++
        "                            ret.subtype.push(subtype);\n" ++
        "                        }\n" ++
        "                    }\n" ++
        "                }\n" ++
        "            }\n" ++
        "        }\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "function f6() {\n" ++
        "    function f5() {\n" ++
        "        function f4() {\n" ++
        "            function f3() {\n" ++
        "                function f2() {\n" ++
        "                    function f1() {\n" ++
        "                        function f0() {\n" ++
        "                            const subtype =\n" ++
        "                                (0,\n" ++
        "                                _helpers_js__WEBPACK_IMPORTED_MODULE_1__.typ" ++
        "e_with_extended_attributes)(\n" ++
        "                                    tokeniser,\n" ++
        "                                    typeName,\n" ++
        "                                ) || tokeniser.error(`Missing ${base.value} " ++
        "subtype`);\n" ++
        "                            ret.subtype.push(subtype);\n" ++
        "                        }\n" ++
        "                    }\n" ++
        "                }\n" ++
        "            }\n" ++
        "        }\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "an assignment in a flat template hole stays on the template's line" {
    const source = "function f5(){function f4(){function f3(){function f2(){function " ++
        "f1(){function f0(){function g(t,e){var a;return " ++
        "/^[a-z]+$/.test(e)?`${(s=t?.p)!==null&&s!==void " ++
        "0?s:\"\"}.${e}`:`${(a=t?.p)!==null&&a!==void " ++
        "0?a:\".\"}[${JSON.stringify(e)}]`}\n" ++
        "}\n" ++
        "}\n" ++
        "}\n" ++
        "}\n" ++
        "}\n" ++
        "}\n";

    const wanted = "function f5() {\n" ++
        "    function f4() {\n" ++
        "        function f3() {\n" ++
        "            function f2() {\n" ++
        "                function f1() {\n" ++
        "                    function f0() {\n" ++
        "                        function g(t, e) {\n" ++
        "                            var a;\n" ++
        "                            return /^[a-z]+$/.test(e)\n" ++
        "                                ? `${(s = t?.p) !== null && s !== void 0 ? " ++
        "s : \"\"}.${e}`\n" ++
        "                                : `${(a = t?.p) !== null && a !== void 0 ? " ++
        "a : \".\"}[${JSON.stringify(e)}]`;\n" ++
        "                        }\n" ++
        "                    }\n" ++
        "                }\n" ++
        "            }\n" ++
        "        }\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "a ternary branch led by a comment keeps the branch level after an assignment breaks" {
    const source_a = "(() => {\n" ++
        "    var __webpack_modules__ = {\n" ++
        "        1: function () {\n" ++
        "            __webpack_require__.n = function (module2) {\n" ++
        "                var getter =\n" ++
        "                    module2 && module2.__esModule\n" ++
        "                        ? /******/\n" ++
        "                          function getDefault() {\n" ++
        "                              return module2[\"default\"];\n" ++
        "                          }\n" ++
        "                        : /******/\n" ++
        "                          function getModuleExports() {\n" ++
        "                              return module2;\n" ++
        "                          };\n" ++
        "                __webpack_require__.d(getter, { a: getter });\n" ++
        "                return getter;\n" ++
        "            };\n" ++
        "        },\n" ++
        "    };\n" ++
        "})();\n";

    const wanted_a = "(() => {\n" ++
        "    var __webpack_modules__ = {\n" ++
        "        1: function () {\n" ++
        "            __webpack_require__.n = function (module2) {\n" ++
        "                var getter =\n" ++
        "                    module2 && module2.__esModule\n" ++
        "                        ? /******/\n" ++
        "                          function getDefault() {\n" ++
        "                              return module2[\"default\"];\n" ++
        "                          }\n" ++
        "                        : /******/\n" ++
        "                          function getModuleExports() {\n" ++
        "                              return module2;\n" ++
        "                          };\n" ++
        "                __webpack_require__.d(getter, { a: getter });\n" ++
        "                return getter;\n" ++
        "            };\n" ++
        "        },\n" ++
        "    };\n" ++
        "})();\n";

    const source_b = "var getter =\n" ++
        "    module2 && module2.__esModule\n" ++
        "        ? /******/\n" ++
        "          function getDefault() {\n" ++
        "              return module2[\"default\"];\n" ++
        "          }\n" ++
        "        : /******/\n" ++
        "          function getModuleExports() {\n" ++
        "              return module2;\n" ++
        "          };\n";

    const wanted_b = "var getter =\n" ++
        "    module2 && module2.__esModule\n" ++
        "        ? /******/\n" ++
        "          function getDefault() {\n" ++
        "              return module2[\"default\"];\n" ++
        "          }\n" ++
        "        : /******/\n" ++
        "          function getModuleExports() {\n" ++
        "              return module2;\n" ++
        "          };\n";

    try expect_formatted(source_a, wanted_a);
    try expect_formatted(source_b, wanted_b);
    try expect_formatted(wanted_a, wanted_a);
    try expect_formatted(wanted_b, wanted_b);
}

test "a loop body that does not fit the header line goes below it" {
    const source = "function a() {\n" ++
        "    function b() {\n" ++
        "        function c() {\n" ++
        "            function d() {\n" ++
        "                if (e.indexOf(\"\\x1B\") !== -1)\n" ++
        "                    for (; r !== void 0; )\n" ++
        "                        (e = rst(e, r.close, r.open)), (r = r.parent);\n" ++
        "            }\n" ++
        "        }\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "function a() {\n" ++
        "    function b() {\n" ++
        "        function c() {\n" ++
        "            function d() {\n" ++
        "                if (e.indexOf(\"\\x1B\") !== -1)\n" ++
        "                    for (; r !== void 0; )\n" ++
        "                        (e = rst(e, r.close, r.open)), (r = r.parent);\n" ++
        "            }\n" ++
        "        }\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

const subscript_binary_nested = "if (x18) {\n" ++
    "    if (x17) {\n" ++
    "        if (x16) {\n" ++
    "            if (x15) {\n" ++
    "                if (x14) {\n" ++
    "                    if (x13) {\n" ++
    "                        if (x12) {\n" ++
    "                            if (x11) {\n" ++
    "                                if (x10) {\n" ++
    "                                    if (x9) {\n" ++
    "                                        if (x8) {\n" ++
    "                                            if (x7) {\n" ++
    "                                                if (x6) {\n" ++
    "                                                    if (x5) {\n" ++
    "                                                        if (x4) {\n" ++
    "                                                            if (x3) {\n" ++
    "                                                                if (x2) {\n" ++
    "                                                                    if (x1) " ++
    "{\n" ++
    "                                                                        if " ++
    "(x0) {\n" ++
    "                                                                            " ++
    "t =\n" ++
    "                                                                            " ++
    "    H[\n" ++
    "                                                                            " ++
    "        b >>\n" ++
    "                                                                            " ++
    "            2\n" ++
    "                                                                            " ++
    "    ];\n" ++
    "                                                                            " ++
    "H[\n" ++
    "                                                                            " ++
    "    (f +\n" ++
    "                                                                            " ++
    "        28) >>\n" ++
    "                                                                            " ++
    "        2\n" ++
    "                                                                            " ++
    "] = e;\n" ++
    "                                                                        }\n" ++
    "                                                                    }\n" ++
    "                                                                }\n" ++
    "                                                            }\n" ++
    "                                                        }\n" ++
    "                                                    }\n" ++
    "                                                }\n" ++
    "                                            }\n" ++
    "                                        }\n" ++
    "                                    }\n" ++
    "                                }\n" ++
    "                            }\n" ++
    "                        }\n" ++
    "                    }\n" ++
    "                }\n" ++
    "            }\n" ++
    "        }\n" ++
    "    }\n" ++
    "}\n";

test "a broken binary inside a subscript indents its right operand" {
    const source = subscript_binary_nested;
    const wanted = subscript_binary_nested;

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "a pattern after other parameters does not hug its function's parentheses" {
    const source = "export async function retrySafariSession(create, { attempts, retryDelayMs = " ++
        "5_000, wait = delay }) {\n" ++
        "  return 1;\n" ++
        "}\n" ++
        "export async function retrySafariSession({ attempts, retryDelayMs = 5_000, " ++
        "wait = delay, create }) {\n" ++
        "  return 1;\n" ++
        "}\n" ++
        "function retrySafariSessionxxxxxxxxxxxxxxx(create, { attempts, " ++
        "retryDelayMs, wait, xxx }) {\n" ++
        "  return 1;\n" ++
        "}\n" ++
        "const f = (create, { attempts, retryDelayMs = 5_000, wait = delay, " ++
        "xxxxxxxxxxxxxxxxx }) => {\n" ++
        "  return 1;\n" ++
        "};\n";

    const wanted = "export async function retrySafariSession(\n" ++
        "    create,\n" ++
        "    { attempts, retryDelayMs = 5_000, wait = delay },\n" ++
        ") {\n" ++
        "    return 1;\n" ++
        "}\n" ++
        "export async function retrySafariSession({\n" ++
        "    attempts,\n" ++
        "    retryDelayMs = 5_000,\n" ++
        "    wait = delay,\n" ++
        "    create,\n" ++
        "}) {\n" ++
        "    return 1;\n" ++
        "}\n" ++
        "function retrySafariSessionxxxxxxxxxxxxxxx(\n" ++
        "    create,\n" ++
        "    { attempts, retryDelayMs, wait, xxx },\n" ++
        ") {\n" ++
        "    return 1;\n" ++
        "}\n" ++
        "const f = (\n" ++
        "    create,\n" ++
        "    { attempts, retryDelayMs = 5_000, wait = delay, xxxxxxxxxxxxxxxxx },\n" ++
        ") => {\n" ++
        "    return 1;\n" ++
        "};\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "a new expression as the callee of another new drops its parentheses" {
    const source = "x = new (new Proxy(o, { construct: () => ({}) }))();\n" ++
        "y = new (new Foo())();\n" ++
        "z = new (new Foo)();\n" ++
        "w = new (foo())();\n" ++
        "v = new (a.b)();\n";

    const wanted = "x = new new Proxy(o, { construct: () => ({}) })();\n" ++
        "y = new new Foo()();\n" ++
        "z = new new Foo()();\n" ++
        "w = new (foo())();\n" ++
        "v = new a.b();\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "an export default expression led by a class or function keeps its parentheses" {
    const source_a = "export default (class {}.getInstance());\n";
    const wanted_a = "export default (class {}.getInstance());\n";
    const source_b = "export default (function f() {}.call(this));\n";
    const wanted_b = "export default (function f() {}.call(this));\n";

    try expect_formatted(source_a, wanted_a);
    try expect_formatted(source_b, wanted_b);
    try expect_formatted(wanted_a, wanted_a);
    try expect_formatted(wanted_b, wanted_b);
}

test "a broken heavy operand in a sequence keeps its continuation indented on the next pass" {
    const source = "function f0(){function f0(){function f0(){function f0(){function " ++
        "f0(){function f0(){function f0(){function f0(){function g(){return " ++
        "B.ref(),++B[oc],B[oc]===B.remoteSettings.maxConcurrentStreams&&this._freeSes" ++
        "sionsCount--,V}}}}}}}}}\n";

    const wanted = "function f0() {\n" ++
        "    function f0() {\n" ++
        "        function f0() {\n" ++
        "            function f0() {\n" ++
        "                function f0() {\n" ++
        "                    function f0() {\n" ++
        "                        function f0() {\n" ++
        "                            function f0() {\n" ++
        "                                function g() {\n" ++
        "                                    return (\n" ++
        "                                        B.ref(),\n" ++
        "                                        ++B[oc],\n" ++
        "                                        B[oc] ===\n" ++
        "                                            " ++
        "B.remoteSettings.maxConcurrentStreams &&\n" ++
        "                                            this._freeSessionsCount--,\n" ++
        "                                        V\n" ++
        "                                    );\n" ++
        "                                }\n" ++
        "                            }\n" ++
        "                        }\n" ++
        "                    }\n" ++
        "                }\n" ++
        "            }\n" ++
        "        }\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "a statement or for head led by the word let keeps its parentheses" {
    const source = "(let[a] = 1);\n" ++
        "(let[a].b.c.e = 1);\n" ++
        "(let)[let[a]] = 1;\n" ++
        "(let[a] ??= 1);\n" ++
        "for ((let) of foo);\n" ++
        "for ((let).a of foo);\n" ++
        "for ((let)[0] in {});\n";

    const wanted = "(let[a] = 1);\n" ++
        "(let[a].b.c.e = 1);\n" ++
        "(let)[let[a]] = 1;\n" ++
        "(let[a] ??= 1);\n" ++
        "for ((let) of foo);\n" ++
        "for ((let).a of foo);\n" ++
        "for ((let)[0] in {});\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "a branch after a commented question mark aligns two columns past the mark" {
    const source = "child = cloneAndReplaceKey(child,\n" ++
        "  prefix + (child.key && (!other || other.key !== child.key) ? " ++
        "// the key can be a number\n" ++
        "  escapeKey('' + child.key) + '/' : '') + childKey);\n";

    const wanted = "child = cloneAndReplaceKey(\n" ++
        "    child,\n" ++
        "    prefix +\n" ++
        "        (child.key && (!other || other.key !== child.key)\n" ++
        "            ? // the key can be a number\n" ++
        "              escapeKey(\"\" + child.key) + \"/\"\n" ++
        "            : \"\") +\n" ++
        "        childKey,\n" ++
        ");\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "a sole operator whose operand holds a body keeps the break after it" {
    const source = "function g() {\n" ++
        "    return e && f.forEach(function (e) {\n" ++
        "                return n(l, e);\n" ++
        "            }), Ra && Ca(l, h), s;\n" ++
        "}\n";

    const wanted = "function g() {\n" ++
        "    return (\n" ++
        "        e &&\n" ++
        "            f.forEach(function (e) {\n" ++
        "                return n(l, e);\n" ++
        "            }),\n" ++
        "        Ra && Ca(l, h),\n" ++
        "        s\n" ++
        "    );\n" ++
        "}\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "parentheses a comment opens or closes are dropped with the comment kept in place" {
    const source = "if (current.elementType === element.type || ( // Keep this check inline\n" ++
        " isCompatibleFamily(current, element) )) {\n" ++
        "  x();\n" ++
        "}\n" ++
        "y = a || ( // c\n" ++
        " b(c) );\n" ++
        "z = a || (b(c) // c\n" ++
        ");\n";

    const wanted = "if (\n" ++
        "    current.elementType === element.type || // Keep this check inline\n" ++
        "    isCompatibleFamily(current, element)\n" ++
        ") {\n" ++
        "    x();\n" ++
        "}\n" ++
        "y =\n" ++
        "    a || // c\n" ++
        "    b(c);\n" ++
        "z = a || b(c); // c\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "a template hole is measured with the blanks its printing adds" {
    const source = "var x = {\n" ++
        "async LIe(t,e,r){A??=await qN(t,{project:a});let m=A.get(e);" ++
        "if(!m)throw new Error(`Binary not found (${e}) for ${hn(a.configuration,t)}`);" ++
        "return await fe.mktempPromise(async w=>{let[,B]=m;});}\n" ++
        "};\n";

    const wanted = "var x = {\n" ++
        "    async LIe(t, e, r) {\n" ++
        "        A ??= await qN(t, { project: a });\n" ++
        "        let m = A.get(e);\n" ++
        "        if (!m)\n" ++
        "            throw new Error(`Binary not found (${e}) for ${hn(a.configuration, t)}`);\n" ++
        "        return await fe.mktempPromise(async (w) => {\n" ++
        "            let [, B] = m;\n" ++
        "        });\n" ++
        "    },\n" ++
        "};\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "an assignment an if without braces holds keeps a plain name on its left" {
    const source = "try {\n" ++
        "  if (!require(\"playwright-core/lib/coreBundle\").utils.isLikelyNpxGlobal())\n" ++
        "    install = require(\"playwright-core/lib/coreBundle\")" ++
        ".registry.installBrowsersForNpmInstall;\n" ++
        "} catch (e) {}\n";

    const wanted = "try {\n" ++
        "    if (!require(\"playwright-core/lib/coreBundle\").utils.isLikelyNpxGlobal())\n" ++
        "        install = require(\"playwright-core/lib/coreBundle\").registry\n" ++
        "            .installBrowsersForNpmInstall;\n" ++
        "} catch (e) {}\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "a coalescing paren in a branch opens before the cast comment of its head" {
    const source = "var target = /** @type {ShadowRoot} */ (root).host\n" ++
        "\t? /** @type {ShadowRoot} */ (root)\n" ++
        "\t: /** @type {Document} */ (root).head ?? /** @type {Document} */ " ++
        "(root.ownerDocument).head;\n" ++
        "x = c ? d : /** @type {D} */ (r).h ?? b;\n";

    const wanted = "var target = /** @type {ShadowRoot} */ (root).host\n" ++
        "    ? /** @type {ShadowRoot} */ (root)\n" ++
        "    : (/** @type {Document} */ (root).head ??\n" ++
        "      /** @type {Document} */ (root.ownerDocument).head);\n" ++
        "x = c ? d : (/** @type {D} */ (r).h ?? b);\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "an object after a logical assignment is a value and a spread abuts its comment" {
    const source = "const run = (context.state.async_consts ??= {\n" ++
        "\tid: context.state.analysis.root.unique('promises'),\n" ++
        "\tdeclaration_count: 0\n" ++
        "});\n" ++
        "x ||= { iddddddddddddddddddd: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, " ++
        "declaration_count: bbbbbbbbbbbbbbbbbbbbbbbbbb };\n" ++
        "const a = [...  /** @type {X} */ (y), .../* c */ z];\n";

    const wanted = "const run = (context.state.async_consts ??= {\n" ++
        "    id: context.state.analysis.root.unique(\"promises\"),\n" ++
        "    declaration_count: 0,\n" ++
        "});\n" ++
        "x ||= {\n" ++
        "    iddddddddddddddddddd: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa,\n" ++
        "    declaration_count: bbbbbbbbbbbbbbbbbbbbbbbbbb,\n" ++
        "};\n" ++
        "const a = [.../** @type {X} */ (y), .../* c */ z];\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "an arrow argument behind a comment breaks after its arrow and is never hugged" {
    const source = "function get_entity_pattern(is_attribute_value) {\n" ++
        "\tconst reg_exp_entities = Object.keys(entities).map(\n" ++
        "\t\t/** @param {any} entity_name */ (entity_name) => " ++
        "reg_exp_entity(entity_name, is_attribute_value)\n" ++
        "\t);\n" ++
        "\tconst reg_exp_entities2 = Object.keys(entities).map(\n" ++
        "\t\t(entity_name) => reg_exp_entity(entity_name, is_attribute_value, " ++
        "xxxxxxxxxxxxxxxxxxxxxxxxxx)\n" ++
        "\t);\n" ++
        "}\n" ++
        "const reg_exp_entity_fn = (entity_name) => reg_exp_entity(entity_name, " ++
        "is_attribute_value_xx);\n" ++
        "foo(aaaaaaaaaaaaaa, (entity_name) => reg_exp_entity(entity_name, " ++
        "is_attribute_value_xxxxxxx), b);\n" ++
        "foo(/* c */ (entity_name) => reg_exp_entity(entity_name, " ++
        "is_attribute_value_xxxxxxxxxxxxxxxxx));\n";

    const wanted = "function get_entity_pattern(is_attribute_value) {\n" ++
        "    const reg_exp_entities = Object.keys(entities).map(\n" ++
        "        /** @param {any} entity_name */ (entity_name) =>\n" ++
        "            reg_exp_entity(entity_name, is_attribute_value),\n" ++
        "    );\n" ++
        "    const reg_exp_entities2 = Object.keys(entities).map((entity_name) =>\n" ++
        "        reg_exp_entity(entity_name, is_attribute_value, " ++
        "xxxxxxxxxxxxxxxxxxxxxxxxxx),\n" ++
        "    );\n" ++
        "}\n" ++
        "const reg_exp_entity_fn = (entity_name) =>\n" ++
        "    reg_exp_entity(entity_name, is_attribute_value_xx);\n" ++
        "foo(\n" ++
        "    aaaaaaaaaaaaaa,\n" ++
        "    (entity_name) => reg_exp_entity(entity_name, " ++
        "is_attribute_value_xxxxxxx),\n" ++
        "    b,\n" ++
        ");\n" ++
        "foo(\n" ++
        "    /* c */ (entity_name) =>\n" ++
        "        reg_exp_entity(entity_name, is_attribute_value_xxxxxxxxxxxxxxxxx),\n" ++
        ");\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "a template before a trailing line comment owes its comma" {
    const source = "assert.htmlEqual(\n" ++
        "\ttarget.innerHTML,\n" ++
        "\t`\n" ++
        "\t\t<button>x</button>\n" ++
        "\t` // if this does not show world - that would also be ok\n" ++
        ");\n" ++
        "f(\n" ++
        "\taaa,\n" ++
        "\tbbb // trailing\n" ++
        ");\n" ++
        "f(\n" ++
        "\taaa,\n" ++
        "\t'str' // trailing\n" ++
        ");\n" ++
        "f(\n" ++
        "\taaa,\n" ++
        "\t`one line` // trailing\n" ++
        ");\n" ++
        "const o = {\n" ++
        "\ta: `x`, // c\n" ++
        "\tb: `\n" ++
        "\t` // d\n" ++
        "};\n";

    const wanted = "assert.htmlEqual(\n" ++
        "    target.innerHTML,\n" ++
        "    `\n" ++
        "\t\t<button>x</button>\n" ++
        "\t`, // if this does not show world - that would also be ok\n" ++
        ");\n" ++
        "f(\n" ++
        "    aaa,\n" ++
        "    bbb, // trailing\n" ++
        ");\n" ++
        "f(\n" ++
        "    aaa,\n" ++
        "    \"str\", // trailing\n" ++
        ");\n" ++
        "f(\n" ++
        "    aaa,\n" ++
        "    `one line`, // trailing\n" ++
        ");\n" ++
        "const o = {\n" ++
        "    a: `x`, // c\n" ++
        "    b: `\n" ++
        "\t`, // d\n" ++
        "};\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "an arrow body keeps parentheses on its leading object alone and arrays need none" {
    const source = "const f = (c) => ({ '&': '&amp;', '<': '&lt;' }[c]);\n" ++
        "const g = (c) => ({ a: 1 }.b());\n" ++
        "const h = (c) => ({ a: 1 }.b);\n" ++
        "(['a', 'b']).forEach(f);\n" ++
        "x = (['a'])[0];\n" ++
        "x = await ([a, b]);\n" ++
        "x = ([a, b])();\n" ++
        "x = [...([a, b])];\n" ++
        "x = !([a]);\n" ++
        "for (const m of ([1, 2])) {}\n";

    const wanted = "const f = (c) => ({ \"&\": \"&amp;\", \"<\": \"&lt;\" })[c];\n" ++
        "const g = (c) => ({ a: 1 }).b();\n" ++
        "const h = (c) => ({ a: 1 }).b;\n" ++
        "[\"a\", \"b\"].forEach(f);\n" ++
        "x = [\"a\"][0];\n" ++
        "x = await [a, b];\n" ++
        "x = [a, b]();\n" ++
        "x = [...[a, b]];\n" ++
        "x = ![a];\n" ++
        "for (const m of [1, 2]) {\n" ++
        "}\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "a member chain left of a compound assignment never breaks" {
    const source = "function f() {\n" ++
        "\tif (a) {\n" ++
        "\t\tif (b) {\n" ++
        "\t\t\tif (c) {\n" ++
        "\t\t\t\tif (d) {\n" ++
        "\t\t\t\t\tif (e) {\n" ++
        "\t\t\t\t\t\tcompiled.js.code += `document.head.innerHTML += " ++
        "\\`<style>${compiled.css.code}</style>\\``;\n" ++
        "\t\t\t\t\t\tcompiled.js.code = `document.head.innerHTML += " ++
        "\\`<style>${compiled.css.code}</style>\\``;\n" ++
        "\t\t\t\t\t\tcompiled.js.code = 'document.head.innerHTML += style compiled " ++
        "css code long long long';\n" ++
        "\t\t\t\t\t}\n" ++
        "\t\t\t\t}\n" ++
        "\t\t\t}\n" ++
        "\t\t}\n" ++
        "\t}\n" ++
        "}\n";

    const wanted = "function f() {\n" ++
        "    if (a) {\n" ++
        "        if (b) {\n" ++
        "            if (c) {\n" ++
        "                if (d) {\n" ++
        "                    if (e) {\n" ++
        "                        compiled.js.code += `document.head.innerHTML += " ++
        "\\`<style>${compiled.css.code}</style>\\``;\n" ++
        "                        compiled.js.code = `document.head.innerHTML += " ++
        "\\`<style>${compiled.css.code}</style>\\``;\n" ++
        "                        compiled.js.code =\n" ++
        "                            \"document.head.innerHTML += style compiled css " ++
        "code long long long\";\n" ++
        "                    }\n" ++
        "                }\n" ++
        "            }\n" ++
        "        }\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "a rest element behind a comment takes no trailing comma" {
    const source = "const snippet = (/** @type {TemplateNode} */ node, /** @type {any[]} */ " ++
        "...args) => {\n" ++
        "\treturn 1;\n" ++
        "};\n" ++
        "const snippet2 = (nodeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee, " ++
        "argumentsssssssssssssssssssssss, ...args) => {\n" ++
        "\treturn 1;\n" ++
        "};\n" ++
        "function f(nodeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee, " ++
        "argumentsssssssssssssssssssssss, /* c */ ...args) {}\n" ++
        "const [aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa, " ++
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb, /* c */ ...rest] = x;\n";

    const wanted = "const snippet = (/** @type {TemplateNode} */ node, /** @type {any[]} */ " ++
        "...args) => {\n" ++
        "    return 1;\n" ++
        "};\n" ++
        "const snippet2 = (\n" ++
        "    nodeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee,\n" ++
        "    argumentsssssssssssssssssssssss,\n" ++
        "    ...args\n" ++
        ") => {\n" ++
        "    return 1;\n" ++
        "};\n" ++
        "function f(\n" ++
        "    nodeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee,\n" ++
        "    argumentsssssssssssssssssssssss,\n" ++
        "    /* c */ ...args\n" ++
        ") {}\n" ++
        "const [\n" ++
        "    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa,\n" ++
        "    bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb,\n" ++
        "    /* c */ ...rest\n" ++
        "] = x;\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "a line comment after an if or while header leads the body and one after else goes above it" {
    const source = "(function (mod) {\n" ++
        "\tif (typeof exports == 'object' && typeof module == 'object') // CommonJS\n" ++
        "\t\tmod(require('../../lib/codemirror'));\n" ++
        "\telse if (typeof define == 'function' && define.amd) // AMD\n" ++
        "\t\tdefine(['../../lib/codemirror'], mod);\n" ++
        "\telse // Plain browser env\n" ++
        "\t\tmod(CodeMirror);\n" ++
        "})(function (CodeMirror) {});\n" ++
        "function f() {\n" ++
        "\tif (this._isStopped) // Check stopped signal after async hop.\n" ++
        "\t\treturn;\n" ++
        "\tfor (const x of y) // c\n" ++
        "\t\tg(x);\n" ++
        "\twhile (a) // c\n" ++
        "\t\tb();\n" ++
        "}\n" ++
        "function f() {\n" ++
        "\tif (this._isStopped)\n" ++
        "\t\t// Check stopped signal after async hop.\n" ++
        "\t\treturn;\n" ++
        "\twhile (a)\n" ++
        "\t\t// c\n" ++
        "\t\tb();\n" ++
        "\tif (a)\n" ++
        "\t\t// c\n" ++
        "\t\tb();\n" ++
        "\telse\n" ++
        "\t\t// d\n" ++
        "\t\tc();\n" ++
        "}\n";

    const wanted = "(function (mod) {\n" ++
        "    if (typeof exports == \"object\" && typeof module == \"object\")\n" ++
        "        // CommonJS\n" ++
        "        mod(require(\"../../lib/codemirror\"));\n" ++
        "    else if (typeof define == \"function\" && define.amd)\n" ++
        "        // AMD\n" ++
        "        define([\"../../lib/codemirror\"], mod);\n" ++
        "    // Plain browser env\n" ++
        "    else mod(CodeMirror);\n" ++
        "})(function (CodeMirror) {});\n" ++
        "function f() {\n" ++
        "    if (this._isStopped)\n" ++
        "        // Check stopped signal after async hop.\n" ++
        "        return;\n" ++
        "    for (const x of y) // c\n" ++
        "        g(x);\n" ++
        "    while (a)\n" ++
        "        // c\n" ++
        "        b();\n" ++
        "}\n" ++
        "function f() {\n" ++
        "    if (this._isStopped)\n" ++
        "        // Check stopped signal after async hop.\n" ++
        "        return;\n" ++
        "    while (a)\n" ++
        "        // c\n" ++
        "        b();\n" ++
        "    if (a)\n" ++
        "        // c\n" ++
        "        b();\n" ++
        "    // d\n" ++
        "    else c();\n" ++
        "}\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "an assigned destructuring pattern ignores its source breaks and breaks after the equals" {
    const source = "function f() {\n" ++
        "\tconst { allowInlineConfig, cwd, fix, fixTypes, ruleFilter, stats, " ++
        "warnIgnored } = eslintOptions;\n" ++
        "\tconst { pluginName: languagePluginName, objectName: localLanguageName } = " ++
        "splitPluginIdentifier(language);\n" ++
        "\tconst { ecmaVersion, sourceType, globals, parser, parserOptions, " ++
        "...otherOptions } = languageOptions;\n" ++
        "}\n" ++
        "function f() {\n" ++
        "\tconst {\n" ++
        "\t\tallowInlineConfig,\n" ++
        "\t\tcwd,\n" ++
        "\t\tfix,\n" ++
        "\t} = eslintOptions;\n" ++
        "\tconst {\n" ++
        "\t\tallowInlineConfig2,\n" ++
        "\t\tcwd,\n" ++
        "\t\tfix,\n" ++
        "\t\tfixTypes,\n" ++
        "\t\truleFilter,\n" ++
        "\t\tstats,\n" ++
        "\t\twarnIgnored,\n" ++
        "\t} = eslintOptions;\n" ++
        "\tlet {\n" ++
        "\t\ta: b,\n" ++
        "\t\tc,\n" ++
        "\t} = d;\n" ++
        "\t({\n" ++
        "\t\ta,\n" ++
        "\t\tb,\n" ++
        "\t} = c);\n" ++
        "}\n";

    const wanted = "function f() {\n" ++
        "    const { allowInlineConfig, cwd, fix, fixTypes, ruleFilter, stats, " ++
        "warnIgnored } =\n" ++
        "        eslintOptions;\n" ++
        "    const { pluginName: languagePluginName, objectName: localLanguageName } " ++
        "=\n" ++
        "        splitPluginIdentifier(language);\n" ++
        "    const { ecmaVersion, sourceType, globals, parser, parserOptions, " ++
        "...otherOptions } =\n" ++
        "        languageOptions;\n" ++
        "}\n" ++
        "function f() {\n" ++
        "    const { allowInlineConfig, cwd, fix } = eslintOptions;\n" ++
        "    const { allowInlineConfig2, cwd, fix, fixTypes, ruleFilter, stats, " ++
        "warnIgnored } =\n" ++
        "        eslintOptions;\n" ++
        "    let { a: b, c } = d;\n" ++
        "    ({ a, b } = c);\n" ++
        "}\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "a bitwise not in a template hole keeps its operand tight" {
    const source = "lines.push(`removeNestedICU(${~nodeOrIcuIndex})`);\n" ++
        "a = `${~b}${!c}${-d}`;\n";

    const wanted = "lines.push(`removeNestedICU(${~nodeOrIcuIndex})`);\n" ++
        "a = `${~b}${!c}${-d}`;\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}
