const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../stdx/bounded/array.zig").ArrayType;
const Language = @import("language.zig").Language;
const Random = @import("../testing/random.zig");
const Token = @import("token.zig");
const Tokens = @import("tokens.zig");
const Lexed = @import("testing/lexed.zig").Lexed;
const stream = @import("stream.zig");

pub const Brackets = struct {
    depths: ArrayType(u32),
    partners: ArrayType(u32),
    source: []const u8,
    tokens: []const Token,

    pub const CapacityError = error{DepthExceeded};

    pub const Bracket = enum {
        brace,
        paren,
        square,
    };

    pub const Classified = struct {
        bracket: Bracket,
        opens: bool,
    };

    pub const Enclosing = struct {
        open: u32,
        commas: u32,
    };

    pub const Range = struct {
        first: u32,
        last: u32,
    };

    const Open = struct {
        bracket: Bracket,
        position: u32,
    };

    pub fn init(gpa: std.mem.Allocator, token_count_max: u32) std.mem.Allocator.Error!Brackets {
        assert(token_count_max > 0);

        var depths: ArrayType(u32) = try .init(gpa, token_count_max);
        errdefer depths.deinit(gpa);

        const partners: ArrayType(u32) = try .init(gpa, token_count_max);

        assert(depths.capacity() == partners.capacity());
        assert(depths.capacity() == token_count_max);

        return .{ .depths = depths, .partners = partners, .source = &.{}, .tokens = &.{} };
    }

    pub fn deinit(brackets: *Brackets, gpa: std.mem.Allocator) void {
        assert(brackets.depths.capacity() == brackets.partners.capacity());
        assert(brackets.partners.capacity() > 0);

        brackets.partners.deinit(gpa);
        brackets.depths.deinit(gpa);
        brackets.* = undefined;
    }

    pub fn argument_around(brackets: *const Brackets, group: Range, index: u32) Range {
        assert(group.first <= index);
        assert(index < group.last);

        const tokens = brackets.tokens;
        const open = group.first;
        const close = group.last;
        var first = if (tokens[open].is_punctuation(.paren_open)) open + 1 else open;

        while (first < close) {
            const last = brackets.argument_end(first, group);

            assert(last >= first);
            assert(last <= close);

            if (index <= last) return .{ .first = first, .last = @min(last, close) };

            first = last + 1;
        }

        return group;
    }

    pub fn argument_end(brackets: *const Brackets, start: u32, group: Range) u32 {
        assert(group.first <= start);

        const tokens = brackets.tokens;
        const until = group.last;

        assert(start <= until);
        assert(until <= tokens.len);
        assert(start < tokens.len);

        const base = brackets.depth_of(start);
        var offset = start;

        while (offset < until) : (offset += 1) {
            if (brackets.depth_of(offset) > base) continue;
            if (tokens[offset].is_punctuation(.comma)) return offset;
        }

        assert(offset == until);

        return until;
    }

    pub fn arguments_of(brackets: *const Brackets, start: u32) ?Range {
        const tokens = brackets.tokens;

        assert(start <= tokens.len);

        var open = start;

        while (open < tokens.len) : (open += 1) {
            if (tokens[open].is_punctuation(.paren_open)) break;

            switch (tokens[open].kind) {
                .block_start, .block_end, .newline => return null,
                else => {},
            }
        }

        if (open == tokens.len) return null;

        const close = brackets.partner_of(open) orelse return null;

        assert(tokens[open].is_punctuation(.paren_open));
        assert(close > open);

        return .{ .first = open, .last = close };
    }

    pub fn build(
        brackets: *Brackets,
        source: []const u8,
        tokens: []const Token,
    ) CapacityError!void {
        assert(source.len <= std.math.maxInt(u32));
        assert(tokens.len <= brackets.partners.capacity());

        brackets.reset(@intCast(tokens.len));
        brackets.source = source;
        brackets.tokens = tokens;

        var stack: [depth_max]Open = undefined;
        var depth: u32 = 0;
        var exceeded = false;

        for (tokens, 0..) |token, position| {
            const index: u32 = @intCast(position);

            const classified = classify(source, token) orelse {
                brackets.depths.buffer[index] = depth;

                continue;
            };

            if (classified.opens) {
                brackets.depths.buffer[index] = depth;

                if (depth < depth_max) {
                    stack[depth] = .{ .bracket = classified.bracket, .position = index };
                } else {
                    exceeded = true;
                }

                depth += 1;

                continue;
            }

            if (depth == 0) continue;

            depth -= 1;
            brackets.depths.buffer[index] = depth;

            if (depth >= depth_max) continue;
            if (stack[depth].bracket != classified.bracket) continue;

            assert(stack[depth].position < index);

            brackets.partners.buffer[stack[depth].position] = index;
            brackets.partners.buffer[index] = stack[depth].position;
        }

        assert(brackets.partners.count() == tokens.len);
        assert(brackets.depths.count() == tokens.len);

        if (exceeded) return error.DepthExceeded;
    }

    fn clear(brackets: *Brackets) void {
        brackets.depths.clear();
        brackets.partners.clear();
        brackets.source = &.{};
        brackets.tokens = &.{};

        assert(brackets.count() == 0);
    }

    pub fn count(brackets: *const Brackets) u32 {
        assert(brackets.depths.count() == brackets.partners.count());
        assert(brackets.partners.count() <= brackets.partners.capacity());

        return brackets.partners.count();
    }

    pub fn depth_of(brackets: *const Brackets, token: u32) u32 {
        assert(token < brackets.count());

        const depth = brackets.depths.get(token);

        assert(depth <= token);

        return depth;
    }

    pub fn enclosing_at(brackets: *const Brackets, offset: u32) ?Enclosing {
        assert(offset < none);

        const tokens = brackets.tokens;

        assert(brackets.count() == tokens.len);

        var cursor = stream.index_starting_from(Token, tokens, offset);
        var commas: u32 = 0;

        assert(cursor <= tokens.len);

        while (cursor > 0) {
            cursor -= 1;

            const token = tokens[cursor];

            const classified = classify(brackets.source, token) orelse {
                if (token.is_punctuation(.comma)) commas += 1;

                continue;
            };

            if (classified.opens) return .{ .open = cursor, .commas = commas };

            const partner = brackets.partner_of(cursor) orelse return null;

            assert(partner < cursor);

            cursor = partner;
        }

        assert(cursor == 0);

        return null;
    }

    pub fn modifier_start(
        brackets: *const Brackets,
        source: []const u8,
        index: u32,
        skip_count_max: u32,
    ) u32 {
        const tokens = brackets.tokens;

        assert(index < tokens.len);
        assert(tokens[index].end() <= source.len);
        assert(skip_count_max > 0);

        const line = stream.line_start_of_token(tokens, source, index);
        var first = index;
        var skipped: u32 = 0;

        assert(line <= index);

        while (first > line) : (skipped += 1) {
            if (skipped == skip_count_max) break;

            var before = first - 1;

            if (tokens[before].is_punctuation(.paren_close)) {
                const open = brackets.open_of(before) orelse break;

                assert(open < before);

                if (open == 0) break;

                before = open - 1;
            }

            if (before < line) break;
            if (!tokens[before].is_keyword(.other)) break;

            first = before;
        }

        assert(first <= index);
        assert(first >= line);
        assert(skipped <= skip_count_max);
        if (first < index) assert(tokens[first].is_keyword(.other));

        return first;
    }

    pub fn open_of(brackets: *const Brackets, close: u32) ?u32 {
        assert(close < brackets.count());

        const partner = brackets.partner_of(close) orelse return null;
        if (partner > close) return null;

        assert(partner < close);

        return partner;
    }

    pub fn partner_of(brackets: *const Brackets, token: u32) ?u32 {
        assert(token < brackets.count());

        const partner = brackets.partners.get(token);
        if (partner == none) return null;

        assert(partner < brackets.count());
        assert(partner != token);
        assert(brackets.partners.get(partner) == token);

        return partner;
    }

    pub fn receiver_start(brackets: *const Brackets, start: u32) u32 {
        const tokens = brackets.tokens;

        assert(start < tokens.len);

        var first = start;

        while (first > 1) {
            if (!tokens[first - 1].is_punctuation(.dot)) break;

            const cursor = brackets.receiver_value(first - 2) orelse return first;

            assert(cursor < first);

            if (!tokens[cursor].ends_a_value()) {
                assert(first - 1 < tokens.len);

                return first - 1;
            }

            const value = value_start(tokens, brackets.receiver_head(cursor));

            assert(value <= cursor);

            if (value >= first) break;

            first = value;
        }

        assert(first <= start);

        return first;
    }

    fn receiver_head(brackets: *const Brackets, cursor: u32) u32 {
        const tokens = brackets.tokens;

        assert(cursor < tokens.len);
        assert(brackets.count() == tokens.len);

        if (tokens[cursor].closes_a_group()) {
            return macro_name(tokens, brackets.open_of(cursor) orelse cursor);
        }

        if (tokens[cursor].kind == .block_end) {
            return macro_name(tokens, block_open(tokens, cursor) orelse cursor);
        }

        return cursor;
    }

    fn receiver_value(brackets: *const Brackets, start: u32) ?u32 {
        const tokens = brackets.tokens;

        assert(start < tokens.len);
        assert(brackets.count() == tokens.len);

        var cursor = start;

        while (is_try(tokens[cursor], brackets.source)) {
            if (cursor == 0) return null;

            cursor -= 1;
        }

        assert(cursor <= start);
        assert(!is_try(tokens[cursor], brackets.source));

        return cursor;
    }

    fn reset(brackets: *Brackets, token_count: u32) void {
        assert(token_count <= brackets.partners.capacity());

        brackets.clear();

        for (0..token_count) |_| {
            brackets.depths.push(0);
            brackets.partners.push(none);
        }

        assert(brackets.count() == token_count);
    }

    pub fn block_open(tokens: []const Token, close: u32) ?u32 {
        assert(close < tokens.len);
        assert(tokens[close].kind == .block_end);

        var depth: u32 = 0;
        var cursor = close + 1;

        while (cursor > 0) {
            cursor -= 1;

            if (tokens[cursor].kind == .block_end) depth += 1;

            if (tokens[cursor].kind == .block_start) {
                depth -|= 1;

                if (depth == 0) return cursor;
            }
        }

        assert(cursor == 0);

        return null;
    }

    pub fn classify(source: []const u8, token: Token) ?Classified {
        assert(source.len <= std.math.maxInt(u32));
        assert(token.end() <= source.len);

        const result: ?Classified = switch (token.kind) {
            .punctuation => |punctuation| switch (punctuation) {
                .paren_open => .{ .bracket = .paren, .opens = true },
                .paren_close => .{ .bracket = .paren, .opens = false },
                .bracket_open => .{ .bracket = .square, .opens = true },
                .bracket_close => .{ .bracket = .square, .opens = false },
                .other => brace_of(source, token),
                else => null,
            },
            .block_end, .block_start => brace_of(source, token),
            .comment, .identifier, .keyword, .newline, .number, .string => null,
        };

        if (result != null) assert(token.length > 0);
        if (result == null) assert(!token.is_punctuation(.paren_open));

        return result;
    }
};

pub const depth_max: u32 = 256;
const none = std.math.maxInt(u32);

fn brace_of(source: []const u8, token: Token) ?Brackets.Classified {
    if (token.length != 1) return null;
    if (token.offset >= source.len) return null;

    return switch (source[token.offset]) {
        '{' => .{ .bracket = .brace, .opens = true },
        '}' => .{ .bracket = .brace, .opens = false },
        else => null,
    };
}

fn is_try(token: Token, source: []const u8) bool {
    if (token.length != 1) return false;
    if (token.offset >= source.len) return false;
    return source[token.offset] == '?';
}

const Built = struct {
    lexed: Lexed,
    pairs: Brackets,

    fn init(language: Language, source: []const u8) !Built {
        assert(source.len <= std.math.maxInt(u32));
        assert(language.lexes());

        var lexed: Lexed = try .init(language, source);
        errdefer lexed.deinit();

        var pairs: Brackets = try .init(std.testing.allocator, token_count_test_max);
        errdefer pairs.deinit(std.testing.allocator);

        try pairs.build(source, lexed.tokens.slice());

        assert(pairs.count() == lexed.tokens.slice().len);

        return .{ .lexed = lexed, .pairs = pairs };
    }

    fn deinit(built: *Built) void {
        assert(built.pairs.count() == built.tokens().len);

        built.pairs.deinit(std.testing.allocator);
        built.lexed.deinit();
    }

    fn tokens(built: *const Built) []const Token {
        return built.lexed.tokens.slice();
    }

    fn word_at(built: *const Built, word: []const u8, ordinal: u32) u32 {
        assert(ordinal > 0);
        assert(word.len <= std.math.maxInt(u32));

        var seen: u32 = 0;

        for (built.tokens(), 0..) |token, index| {
            if (!std.mem.eql(u8, token.text(built.lexed.source), word)) continue;

            seen += 1;

            if (seen == ordinal) {
                assert(index < built.tokens().len);

                return @intCast(index);
            }
        }

        unreachable;
    }

    fn punctuation_last(built: *const Built, punctuation: Token.Punctuation) u32 {
        assert(punctuation != .other);

        var found: ?u32 = null;

        for (built.tokens(), 0..) |token, index| {
            if (token.is_punctuation(punctuation)) found = @intCast(index);
        }

        return found.?;
    }

    fn text_of(built: *const Built, index: u32) []const u8 {
        assert(index < built.tokens().len);

        return built.tokens()[index].text(built.lexed.source);
    }
};

const token_count_test_max = 4_096;

fn bracket_of(source: []const u8, token: Token) ?Brackets.Bracket {
    assert(source.len <= std.math.maxInt(u32));
    assert(token.end() <= source.len);

    const classified = Brackets.classify(source, token) orelse return null;
    return classified.bracket;
}

fn angle_open(tokens: []const Token, close: u32) ?u32 {
    assert(close < tokens.len);
    assert(tokens[close].is_punctuation(.greater));

    var depth: u32 = 0;
    var cursor = close + 1;

    while (cursor > 0) {
        cursor -= 1;

        if (tokens[cursor].is_punctuation(.greater)) depth += 1;

        if (tokens[cursor].is_punctuation(.less)) {
            depth -|= 1;

            if (depth == 0) return cursor;
        }
    }

    assert(cursor == 0);

    return null;
}

fn macro_name(tokens: []const Token, open: u32) u32 {
    assert(open < tokens.len);

    if (open == 0) return open;

    if (tokens[open - 1].is_punctuation(.bang)) {
        assert(open - 1 < tokens.len);

        return open - 1;
    }

    return open;
}

fn path_start(tokens: []const Token, start: u32) u32 {
    assert(start <= tokens.len);

    var cursor = start;

    while (cursor > 0) {
        const before = cursor - 1;

        if (tokens[before].kind == .identifier) {
            cursor = before;

            continue;
        }

        if (tokens[before].is_punctuation(.greater)) {
            if (angle_open(tokens, before)) |opened| {
                assert(opened < before);

                cursor = opened;

                continue;
            }
        }

        if (before == 0) break;
        if (!tokens[before].is_punctuation(.colon)) break;

        if (tokens[before].length == 2) {
            cursor = before;

            continue;
        }

        if (!tokens[before - 1].is_punctuation(.colon)) break;

        cursor = before - 1;
    }

    assert(cursor <= start);
    if (cursor < start) assert(tokens[cursor].kind != .newline);

    return cursor;
}

fn value_start(tokens: []const Token, start: u32) u32 {
    assert(start <= tokens.len);

    const cursor = path_start(tokens, start);

    assert(cursor <= start);

    if (cursor == 0) return cursor;

    assert(cursor - 1 < tokens.len);

    return switch (tokens[cursor - 1].kind) {
        .number, .string => cursor - 1,
        else => cursor,
    };
}

test Brackets {
    const gpa = std.testing.allocator;
    const source = "call(first, [second, third]);\n";
    var tokens: Tokens = try .init(gpa, 64);
    defer tokens.deinit(gpa);

    try tokens.lex(.of(.python), source);

    var brackets: Brackets = try .init(gpa, 64);
    defer brackets.deinit(gpa);

    try brackets.build(source, tokens.slice());

    try std.testing.expectEqual(9, brackets.partner_of(1).?);
    try std.testing.expectEqual(8, brackets.partner_of(4).?);
    try std.testing.expectEqual(2, brackets.depth_of(5));
    try std.testing.expectEqual(null, brackets.partner_of(0));
}

test "a partner is mutual and kind matched" {
    const source = "fn f(a: [u8; 4]) -> Vec<u8> { let x = g(h([1, 2])); }\n";
    var built: Built = try .init(.rust, source);
    defer built.deinit();

    var matched: u32 = 0;

    for (built.tokens(), 0..) |token, position| {
        const index: u32 = @intCast(position);
        const partner = built.pairs.partner_of(index) orelse continue;

        try std.testing.expectEqual(index, built.pairs.partner_of(partner).?);
        const mate = built.tokens()[partner];

        try std.testing.expectEqual(bracket_of(source, token), bracket_of(source, mate));

        matched += 1;
    }

    try std.testing.expectEqual(12, matched);
}

test "a partner names the matching byte" {
    var built: Built = try .init(.python, "g(h([1, 2]))\n");
    defer built.deinit();

    const opener = built.word_at("(", 1);
    const partner = built.pairs.partner_of(opener).?;

    try std.testing.expectEqualStrings(")", built.text_of(partner));
    try std.testing.expect(partner > opener);
}

test "an unmatched bracket has no partner" {
    var built: Built = try .init(.python, "f((a)\n");
    defer built.deinit();

    try std.testing.expectEqual(null, built.pairs.partner_of(built.word_at("(", 1)));
}

test "a closer without an opener has no partner" {
    var built: Built = try .init(.python, "a)b\n");
    defer built.deinit();

    for (0..built.pairs.count()) |index| {
        try std.testing.expectEqual(null, built.pairs.partner_of(@intCast(index)));
    }
}

test "a crossed pair matches neither" {
    const source = "f([a)]\n";
    var built: Built = try .init(.python, source);
    defer built.deinit();

    for (built.tokens(), 0..) |token, position| {
        if (Brackets.classify(source, token) == null) continue;

        try std.testing.expectEqual(null, built.pairs.partner_of(@intCast(position)));
    }
}

test "a depth counts the brackets enclosing a token" {
    var built: Built = try .init(.python, "f(a, g(b), [c])\n");
    defer built.deinit();

    var commas: u32 = 0;

    for (built.tokens(), 0..) |token, position| {
        if (!token.is_punctuation(.comma)) continue;

        try std.testing.expectEqual(1, built.pairs.depth_of(@intCast(position)));

        commas += 1;
    }

    try std.testing.expectEqual(2, commas);
}

test "a brace pairs through the other punctuation kind" {
    var built: Built = try .init(.rust, "fn f() { if a { b(); } }\n");
    defer built.deinit();

    const partner = built.pairs.partner_of(built.word_at("{", 1)).?;

    try std.testing.expectEqualStrings("}", built.text_of(partner));
}

test "nesting past the bound is reported and the pairs it keeps stay consistent" {
    const gpa = std.testing.allocator;
    const open_count = depth_max + 8;
    const opens: [open_count]u8 = @splat('(');
    const closes: [open_count]u8 = @splat(')');
    const source = opens ++ closes ++ "\n";
    var lexed: Lexed = try .init(.python, source);
    defer lexed.deinit();

    var pairs: Brackets = try .init(gpa, token_count_test_max);
    defer pairs.deinit(gpa);

    try std.testing.expectError(error.DepthExceeded, pairs.build(source, lexed.tokens.slice()));
    try std.testing.expectEqual(lexed.tokens.slice().len, pairs.count());
    try std.testing.expectEqual(2 * open_count - 1, pairs.partner_of(0).?);
    try std.testing.expectEqual(2 * open_count - depth_max, pairs.partner_of(depth_max - 1).?);
    try std.testing.expectEqual(null, pairs.partner_of(depth_max));

    for (0..pairs.count()) |position| {
        const index: u32 = @intCast(position);
        const partner = pairs.partner_of(index) orelse continue;

        try std.testing.expectEqual(index, pairs.partner_of(partner).?);
    }
}

test "every pair is properly nested on byte soup" {
    const alphabet = "()[]{}abc,.;\n ";
    var random: Random = .init(0x9E37_79B9_7F4A_7C15);
    var buffer: [128]u8 = undefined;

    for (0..256) |_| {
        const length = random.below(128);

        for (buffer[0..length]) |*byte| byte.* = alphabet[random.below(alphabet.len)];

        const source = buffer[0..length];
        var built: Built = try .init(.python, source);
        defer built.deinit();

        for (built.tokens(), 0..) |token, position| {
            const index: u32 = @intCast(position);
            const partner = built.pairs.partner_of(index) orelse continue;
            const mate = Brackets.classify(source, built.tokens()[partner]).?;
            const held = Brackets.classify(source, token).?;

            try std.testing.expectEqual(index, built.pairs.partner_of(partner).?);
            try std.testing.expectEqual(held.bracket, mate.bracket);
            try std.testing.expectEqual(held.opens, !mate.opens);
        }
    }
}

test "a generic argument list opens at its own angle" {
    var built: Built = try .init(.rust, "fn held(value: Map<Key<u32>, Value>) {\n}\n");
    defer built.deinit();

    const open = angle_open(built.tokens(), built.punctuation_last(.greater)).?;

    try std.testing.expect(built.tokens()[open].is_punctuation(.less));
    try std.testing.expectEqual(built.word_at("<", 1), open);
}

test "an unopened angle has no open" {
    var built: Built = try .init(.rust, "fn held(value: u32) {\n    let _ = 1 > 0;\n}\n");
    defer built.deinit();

    const close = built.word_at(">", 1);

    try std.testing.expectEqual(null, angle_open(built.tokens(), close));
}

test "an argument walk finds the one the index sits in" {
    const source = "fn held() {\n    call(first, second(inner, deep), third);\n}\n";
    var built: Built = try .init(.rust, source);
    defer built.deinit();

    const open = built.word_at("(", 2);
    const close = built.punctuation_last(.paren_close);
    const deep = built.word_at("deep", 1);
    const range = built.pairs.argument_around(.{ .first = open, .last = close }, deep);

    try std.testing.expectEqualStrings("second", built.text_of(range.first));
    try std.testing.expectEqualStrings(",", built.text_of(range.last));
}

test "the first argument is the one after the parenthesis" {
    var built: Built = try .init(.rust, "fn held() {\n    call(first, second);\n}\n");
    defer built.deinit();

    const open = built.word_at("(", 2);
    const close = built.punctuation_last(.paren_close);
    const held = built.word_at("first", 1);
    const range = built.pairs.argument_around(.{ .first = open, .last = close }, held);

    try std.testing.expectEqualStrings("first", built.text_of(range.first));
}

test "an argument ends at the comma of its own depth" {
    var built: Built = try .init(.rust, "fn held() {\n    call(first(a, b), second);\n}\n");
    defer built.deinit();

    const start = built.word_at("first", 1);
    const close = built.punctuation_last(.paren_close);
    const end = built.pairs.argument_end(start, .{ .first = start, .last = close });

    try std.testing.expect(built.tokens()[end].is_punctuation(.comma));
    try std.testing.expectEqualStrings("second", built.text_of(end + 1));
}

test "an argument with no comma ends where the walk does" {
    var built: Built = try .init(.rust, "fn held() {\n    call(only);\n}\n");
    defer built.deinit();

    const start = built.word_at("only", 1);
    const end = built.pairs.argument_end(start, .{ .first = start, .last = start + 1 });

    try std.testing.expectEqual(start + 1, end);
}

test "the enclosing bracket is the innermost opener and the commas at its level" {
    const source = "fn held() {\n    call(first, g(a, b), [1, 2], third);\n}\n";
    var built: Built = try .init(.rust, source);
    defer built.deinit();

    const tokens = built.tokens();
    const open = built.word_at("(", 2);
    const third = tokens[built.word_at("third", 1)].offset;
    const inside_g = tokens[built.word_at("b", 1)].offset;
    const inside_list = tokens[built.word_at("2", 1)].offset;
    const after_open = tokens[open].offset + 1;
    const at_third = built.pairs.enclosing_at(third).?;
    const at_open = built.pairs.enclosing_at(after_open).?;

    try std.testing.expectEqual(Brackets.Enclosing{ .open = open, .commas = 3 }, at_third);
    try std.testing.expectEqual(Brackets.Enclosing{ .open = open, .commas = 0 }, at_open);
    try std.testing.expectEqual(null, built.pairs.enclosing_at(0));

    const body = built.pairs.enclosing_at(tokens[open].offset).?;

    try std.testing.expectEqualStrings("{", built.text_of(body.open));
    try std.testing.expectEqual(0, body.commas);

    const g = built.pairs.enclosing_at(inside_g).?;
    const inner: Brackets.Enclosing = .{ .open = built.word_at("(", 3), .commas = 1 };

    try std.testing.expectEqual(inner, g);

    const list = built.pairs.enclosing_at(inside_list).?;

    try std.testing.expectEqualStrings("[", built.text_of(list.open));
    try std.testing.expectEqual(1, list.commas);
}

test "an unmatched closer before the offset leaves nothing enclosing" {
    const source = "fn held() {\n    ) x;\n}\n";
    var built: Built = try .init(.rust, source);
    defer built.deinit();

    const x = built.tokens()[built.word_at("x", 1)].offset;

    try std.testing.expectEqual(null, built.pairs.enclosing_at(x));

    var empty: Brackets = try .init(std.testing.allocator, 4);
    defer empty.deinit(std.testing.allocator);

    try std.testing.expectEqual(null, empty.enclosing_at(3));
}

fn word_index(lexed: *const Lexed, word: []const u8) u32 {
    assert(word.len <= std.math.maxInt(u32));

    for (lexed.tokens.slice(), 0..) |token, index| {
        if (std.mem.eql(u8, token.text(lexed.source), word)) {
            assert(index < lexed.tokens.slice().len);

            return @intCast(index);
        }
    }

    unreachable;
}

test "a qualified path starts at its root" {
    const source = "fn held() {\n    let value = one::two::three(4);\n}\n";
    var lexed: Lexed = try .init(.rust, source);
    defer lexed.deinit();

    const leaf = word_index(&lexed, "three");

    try std.testing.expectEqual(word_index(&lexed, "one"), path_start(lexed.tokens.slice(), leaf));
}

test "a generic path starts before its arguments" {
    const source = "fn held() {\n    let value = Vec::<u32>::new();\n}\n";
    var lexed: Lexed = try .init(.rust, source);
    defer lexed.deinit();

    const leaf = word_index(&lexed, "new");

    try std.testing.expectEqual(word_index(&lexed, "Vec"), path_start(lexed.tokens.slice(), leaf));
}
