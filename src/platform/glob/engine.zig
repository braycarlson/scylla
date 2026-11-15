const std = @import("std");
const assert = std.debug.assert;
const bounded = @import("../../stdx/bounded.zig");
const path_platform = @import("../path/platform.zig");

pub const Anchoring = enum {
    anchored,
    inferred,
    unanchored,
};

pub const CapacityError = error{
    BraceTooDeep,
    BytesExhausted,
    ClassesExhausted,
    PatternsExhausted,
    VariantsExhausted,
};

pub const Error = CapacityError || SyntaxError;

pub const SyntaxError = error{
    BraceUnclosed,
    ClassUnclosed,
    DoubleStarComponent,
    Empty,
    EscapeUnfinished,
};

const Brace = union(enum) {
    absent,
    present: Row,
};

pub const Diagnostic = struct {
    offset: u32,
};

const Fixed = struct {
    head: Row,
    star: bool,
    tail: Row,
};

pub const Row = struct {
    end: u32,
    start: u32,

    pub fn empty(row: Row) bool {
        return row.start >= row.end;
    }
};

pub const Shape = union(enum) {
    general,
    segment_last: Fixed,
    segment_path: Fixed,
    segment_path_under: Fixed,
    segment_under: Fixed,
    whole: Fixed,
    whole_prefix: Fixed,
};

pub const Token = union(enum) {
    any,
    class: Class,
    literal: u8,
    segment_star,
    star,
    tail_star,

    pub const Class = struct {
        negated: bool,
        offset: u32,
    };

    fn skippable(token: Token) bool {
        if (token == .class) assert(token.class.offset % class_bytes == 0);

        return switch (token) {
            .star, .tail_star => true,
            .any, .class, .literal, .segment_star => false,
        };
    }
};

pub const Scratch = struct {
    live: bounded.ArrayType(u64),
    next: bounded.ArrayType(u64),

    pub fn init(gpa: std.mem.Allocator, token_count_max: u32) std.mem.Allocator.Error!Scratch {
        assert(token_count_max > 0);

        const words = words_for(token_count_max);
        var live: bounded.ArrayType(u64) = try .init(gpa, words);
        errdefer live.deinit(gpa);

        var next: bounded.ArrayType(u64) = try .init(gpa, words);
        errdefer next.deinit(gpa);

        for (0..words) |_| {
            live.push(0);
            next.push(0);
        }

        assert(live.full());
        assert(next.full());

        return .{ .live = live, .next = next };
    }

    pub fn deinit(scratch: *Scratch, gpa: std.mem.Allocator) void {
        assert(scratch.live.full());
        assert(scratch.next.full());

        scratch.live.deinit(gpa);
        scratch.next.deinit(gpa);
        scratch.* = undefined;
    }

    pub fn capacity(scratch: *const Scratch) u32 {
        assert(scratch.live.full());
        assert(scratch.live.count() == scratch.next.count());

        return scratch.live.count() * bits_per_word;
    }
};

pub const class_bytes: u32 = 32;
pub const platform_native = path_platform.platform_native;
pub const separator: u8 = '/';
pub const variant_bytes_max: u32 = 8_192;
pub const variant_count_max: u32 = 128;
const bits_per_byte: u32 = 8;
const bits_per_word: u32 = 64;
const brace_depth_max: u32 = 8;
const expansion_steps_max: u32 = 1_024;
const nibble_low: u8 = 0x07;
const nibble_shift: u3 = 3;
const word_mask: u32 = 63;
const word_shift: u5 = 6;

comptime {
    assert(class_bytes * bits_per_byte == 256);
    assert((@as(u32, 1) << word_shift) == bits_per_word);
    assert(word_mask == bits_per_word - 1);
}

pub fn message(err: Error) []const u8 {
    return switch (err) {
        error.BraceTooDeep => "the alternation nests or expands further than the reader reads",
        error.BraceUnclosed => "the alternation opens with { and never closes",
        error.BytesExhausted => "the pattern table has no room left for the pattern's bytes",
        error.ClassUnclosed => "the character class opens with [ and never closes",
        error.ClassesExhausted => "the pattern table has no room left for a character class",
        error.DoubleStarComponent => "** stands as a whole path component or not at all",
        error.Empty => "the pattern names nothing",
        error.EscapeUnfinished => "the pattern ends in a backslash that escapes nothing",
        error.PatternsExhausted => "the pattern table has no room left for another pattern",
        error.VariantsExhausted => "the pattern expands to more variants than the reader holds",
    };
}

pub fn compile(
    pattern: []const u8,
    tokens: *bounded.ArrayType(Token),
    classes: *bounded.ArrayType(u8),
    diagnostic: *Diagnostic,
) Error!void {
    assert(pattern.len <= variant_bytes_max);
    assert(tokens.count() <= tokens.capacity());

    var offset: u32 = 0;

    for (0..variant_bytes_max + 1) |_| {
        if (offset >= pattern.len) break;

        const byte = pattern[offset];

        offset = switch (byte) {
            '\\' => try escaped(pattern, offset, tokens, diagnostic),
            '*' => try star(pattern, offset, tokens, diagnostic),
            '[' => try class(pattern, offset, tokens, classes, diagnostic),
            '?' => try literal(tokens, .any, offset),
            else => try literal(tokens, .{ .literal = byte }, offset),
        };
    }

    assert(offset >= pattern.len);
}

pub fn expand(
    pattern: []const u8,
    work: *bounded.ArrayType(u8),
    pending: *bounded.ArrayType(Row),
    spans: *bounded.ArrayType(Row),
    diagnostic: *Diagnostic,
) Error!void {
    assert(pattern.len > 0);
    assert(pending.empty());

    const seed = try appended(work, pattern);

    if (pending.full()) return error.VariantsExhausted;

    pending.push(seed);

    for (0..expansion_steps_max) |_| {
        const span = pending.pop() orelse return;
        const brace = try brace_of(work.const_slice(), span, diagnostic);

        switch (brace) {
            .absent => {
                if (spans.full()) return error.VariantsExhausted;

                spans.push(span);
            },
            .present => |held| try split(work, pending, span, held),
        }
    }

    if (pending.empty()) return;

    diagnostic.offset = 0;

    return error.BraceTooDeep;
}

fn is_member(bitmap: []const u8, byte: u8) bool {
    assert(bitmap.len == class_bytes);

    const slot = byte >> nibble_shift;
    const bit: u3 = @intCast(byte & nibble_low);

    assert(slot < bitmap.len);

    return (bitmap[slot] >> bit) & 1 == 1;
}

pub fn classify(tokens: []const Token, row: Row) Shape {
    assert(row.start <= row.end);
    assert(row.end <= tokens.len);

    const run = tokens[row.start..row.end];
    const segmented = run.len > 0 and run[0] == .segment_star;
    if (!segmented) return rooted(run, row.start);

    const base = row.start + 1;
    const rest = run[1..];

    const under = rest.len >= 2 and rest[rest.len - 1] == .tail_star and
        is_separator_literal(rest[rest.len - 2]);

    const middle = if (under) rest[0 .. rest.len - 2] else rest;
    const fixed = split_fixed(middle, base) orelse return .general;

    for (middle) |token| {
        if (!is_separator_literal(token)) continue;
        if (under) return .{ .segment_path_under = fixed };
        return .{ .segment_path = fixed };
    }

    if (under) return .{ .segment_under = fixed };
    return .{ .segment_last = fixed };
}

pub fn MatcherType(comptime platform: path_platform.Platform) type {
    return struct {
        const separators = path_platform.PathType(platform);

        pub fn matches(
            row: Row,
            tokens: []const Token,
            classes: []const u8,
            scratch: *Scratch,
            subject: []const u8,
        ) bool {
            assert(row.start <= row.end);
            assert(row.end <= tokens.len);
            assert(classes.len <= std.math.maxInt(u32));
            assert(subject.len <= std.math.maxInt(u32));

            if (row.empty()) return subject.len == 0;

            bits_clear(scratch.live.slice(), row);
            bit_enter(scratch.live.slice(), row, tokens, row.start);
            bits_close(scratch.live.slice(), row, tokens);

            for (subject) |byte| {
                bits_clear(scratch.next.slice(), row);

                for (row.start..row.end) |index| {
                    if (!bit_test(scratch.live.slice(), @intCast(index))) continue;

                    step(row, tokens, classes, scratch.next.slice(), @intCast(index), byte);
                }

                bits_close(scratch.next.slice(), row, tokens);
                std.mem.swap(bounded.ArrayType(u64), &scratch.live, &scratch.next);

                if (bits_empty(scratch.live.slice(), row)) return false;
            }

            return bit_test(scratch.live.slice(), row.end);
        }

        pub fn shaped(
            shape: Shape,
            tokens: []const Token,
            classes: []const u8,
            subject: []const u8,
        ) ?bool {
            assert(classes.len % class_bytes == 0);
            assert(tokens.len > 0);
            assert(subject.len <= std.math.maxInt(u32));
            if (shape == .general) return null;

            return switch (shape) {
                .general => null,
                .segment_last => |fixed| run_matches(
                    tokens,
                    classes,
                    fixed,
                    component_last(subject),
                ),
                .segment_path => |fixed| path_matches(tokens, classes, fixed, subject),
                .segment_path_under => |fixed| path_under_matches(tokens, classes, fixed, subject),
                .segment_under => |fixed| under_matches(tokens, classes, fixed, subject),
                .whole => |fixed| run_matches(tokens, classes, fixed, subject),
                .whole_prefix => |fixed| rooted_prefix_matches(tokens, classes, fixed, subject),
            };
        }

        fn byte_matches(token: Token, classes: []const u8, byte: u8) bool {
            assert(classes.len % class_bytes == 0);
            if (token == .class) assert(token.class.offset % class_bytes == 0);

            return switch (token) {
                .any => !separators.is_separator(byte),
                .class => |held| class_matches(held, classes, byte),
                .literal => |held| literal_matches(held, byte),
                .segment_star, .star, .tail_star => false,
            };
        }

        fn class_matches(held: Token.Class, classes: []const u8, byte: u8) bool {
            assert(held.offset % class_bytes == 0);
            assert(held.offset + class_bytes <= classes.len);

            if (separators.is_separator(byte)) return false;

            const bitmap = classes[held.offset..][0..class_bytes];
            return is_member(bitmap, byte) != held.negated;
        }

        fn component_last(subject: []const u8) []const u8 {
            assert(subject.len <= std.math.maxInt(u32));

            for (0..subject.len) |back| {
                const index = subject.len - back;

                assert(index > 0);

                if (separators.is_separator(subject[index - 1])) return subject[index..];
            }

            return subject;
        }

        fn literal_matches(held: u8, byte: u8) bool {
            if (byte == held) return true;
            if (held != separator) return false;
            return separators.is_separator(byte);
        }

        fn path_matches(
            tokens: []const Token,
            classes: []const u8,
            fixed: Fixed,
            subject: []const u8,
        ) bool {
            assert(fixed.head.start <= fixed.head.end);
            assert(fixed.tail.start <= fixed.tail.end);
            assert(tokens.len <= std.math.maxInt(u32));
            assert(classes.len <= std.math.maxInt(u32));
            assert(subject.len <= std.math.maxInt(u32));

            for (0..subject.len + 1) |start| {
                if (!component_starts(subject, start)) continue;
                if (run_matches(tokens, classes, fixed, subject[start..])) return true;
            }

            return false;
        }

        fn path_under_matches(
            tokens: []const Token,
            classes: []const u8,
            fixed: Fixed,
            subject: []const u8,
        ) bool {
            assert(fixed.head.start <= fixed.head.end);
            assert(fixed.tail.start <= fixed.tail.end);
            assert(tokens.len <= std.math.maxInt(u32));
            assert(classes.len <= std.math.maxInt(u32));
            assert(subject.len <= std.math.maxInt(u32));

            for (0..subject.len + 1) |start| {
                if (!component_starts(subject, start)) continue;

                const rest = subject[start..];

                if (fixed.star) {
                    if (starred_under_matches(tokens, classes, fixed, rest)) return true;
                } else {
                    const length = run_length(fixed.head);

                    if (rest.len <= length) continue;
                    if (!separators.is_separator(rest[length])) continue;
                    if (prefix_matches(tokens, classes, fixed.head, rest)) return true;
                }
            }

            return false;
        }

        fn starred_under_matches(
            tokens: []const Token,
            classes: []const u8,
            fixed: Fixed,
            rest: []const u8,
        ) bool {
            assert(fixed.star);
            assert(tokens.len <= std.math.maxInt(u32));
            assert(classes.len <= std.math.maxInt(u32));
            assert(rest.len <= std.math.maxInt(u32));

            for (rest, 0..) |byte, end| {
                if (!separators.is_separator(byte)) continue;
                if (run_matches(tokens, classes, fixed, rest[0..end])) return true;
            }

            return false;
        }

        fn component_starts(subject: []const u8, start: usize) bool {
            assert(start <= subject.len);

            if (start == 0) return true;

            return separators.is_separator(subject[start - 1]);
        }

        fn prefix_matches(
            tokens: []const Token,
            classes: []const u8,
            run: Row,
            bytes: []const u8,
        ) bool {
            assert(run.start <= run.end);
            assert(run.end <= tokens.len);
            assert(classes.len <= std.math.maxInt(u32));

            const held = tokens[run.start..run.end];
            if (bytes.len < held.len) return false;

            for (held, bytes[0..held.len]) |token, byte| {
                if (!byte_matches(token, classes, byte)) return false;
            }

            return true;
        }

        fn rooted_prefix_matches(
            tokens: []const Token,
            classes: []const u8,
            fixed: Fixed,
            subject: []const u8,
        ) bool {
            if (!prefix_matches(tokens, classes, fixed.head, subject)) return false;
            if (!fixed.star) return true;

            const head_length = run_length(fixed.head);

            assert(head_length <= subject.len);

            const rest = subject[head_length..];
            var limit: usize = rest.len;

            for (rest, 0..) |byte, index| {
                if (separators.is_separator(byte)) {
                    limit = index;

                    break;
                }
            }

            assert(limit <= rest.len);

            for (0..limit + 1) |gap| {
                if (prefix_matches(tokens, classes, fixed.tail, rest[gap..])) return true;
            }

            return false;
        }

        fn run_matches(
            tokens: []const Token,
            classes: []const u8,
            fixed: Fixed,
            subject: []const u8,
        ) bool {
            assert(tokens.len <= std.math.maxInt(u32));
            assert(classes.len <= std.math.maxInt(u32));
            assert(fixed.head.start <= fixed.head.end);
            assert(subject.len <= std.math.maxInt(u32));

            const head_length = run_length(fixed.head);

            assert(fixed.tail.start <= fixed.tail.end);

            if (!fixed.star) {
                if (subject.len != head_length) return false;
                return prefix_matches(tokens, classes, fixed.head, subject);
            }

            const tail_length = run_length(fixed.tail);
            if (subject.len < tail_length) return false;

            const gap_end = subject.len - tail_length;
            if (gap_end < head_length) return false;
            if (!prefix_matches(tokens, classes, fixed.head, subject)) return false;
            if (!suffix_matches(tokens, classes, fixed.tail, subject)) return false;

            for (subject[head_length..gap_end]) |byte| {
                if (separators.is_separator(byte)) return false;
            }

            return true;
        }

        fn step(
            row: Row,
            tokens: []const Token,
            classes: []const u8,
            next: []u64,
            index: u32,
            byte: u8,
        ) void {
            assert(index >= row.start);
            assert(index < row.end);
            assert(tokens.len <= std.math.maxInt(u32));
            assert(classes.len <= std.math.maxInt(u32));
            assert(next.len <= std.math.maxInt(u32));

            const token = tokens[index];
            const forward = index + 1;

            switch (token) {
                .any, .class, .literal => {
                    if (byte_matches(token, classes, byte)) bit_enter(next, row, tokens, forward);
                },
                .segment_star => {
                    bit_set(next, index);

                    if (separators.is_separator(byte)) bit_enter(next, row, tokens, forward);
                },
                .star => {
                    if (!separators.is_separator(byte)) bit_set(next, index);
                },
                .tail_star => bit_set(next, index),
            }
        }

        fn suffix_matches(
            tokens: []const Token,
            classes: []const u8,
            run: Row,
            bytes: []const u8,
        ) bool {
            assert(run.start <= run.end);
            assert(run.end <= tokens.len);
            assert(classes.len <= std.math.maxInt(u32));

            const held = tokens[run.start..run.end];
            if (bytes.len < held.len) return false;

            for (held, bytes[bytes.len - held.len ..]) |token, byte| {
                if (!byte_matches(token, classes, byte)) return false;
            }

            return true;
        }

        fn under_matches(
            tokens: []const Token,
            classes: []const u8,
            fixed: Fixed,
            subject: []const u8,
        ) bool {
            assert(fixed.head.start <= fixed.head.end);
            assert(fixed.tail.start <= fixed.tail.end);
            assert(tokens.len <= std.math.maxInt(u32));
            assert(classes.len <= std.math.maxInt(u32));
            assert(subject.len <= std.math.maxInt(u32));

            var segment_start: usize = 0;

            for (subject, 0..) |byte, index| {
                if (!separators.is_separator(byte)) continue;

                assert(segment_start <= index);

                if (run_matches(tokens, classes, fixed, subject[segment_start..index])) return true;

                segment_start = index + 1;
            }

            assert(segment_start <= subject.len);

            return false;
        }
    };
}

fn appended(work: *bounded.ArrayType(u8), bytes: []const u8) Error!Row {
    assert(bytes.len > 0);

    if (work.unused_capacity() < bytes.len) return error.VariantsExhausted;

    const start = work.count();

    work.push_slice(bytes);

    assert(work.count() > start);

    return .{ .end = work.count(), .start = start };
}

fn append_run(work: *bounded.ArrayType(u8), start: u32, end: u32) Error!void {
    assert(start <= end);
    assert(end <= work.count());

    if (work.unused_capacity() < end - start) return error.VariantsExhausted;

    work.push_slice(work.const_slice()[start..end]);
}

fn bit_set(words: []u64, index: u32) void {
    assert(index < std.math.maxInt(u32));

    const slot = index >> word_shift;

    assert(slot < words.len);

    words[slot] |= @as(u64, 1) << @intCast(index & word_mask);
}

fn bit_test(words: []const u64, index: u32) bool {
    assert(index < std.math.maxInt(u32));

    const slot = index >> word_shift;

    assert(slot < words.len);

    return (words[slot] >> @intCast(index & word_mask)) & 1 == 1;
}

fn bits_clear(words: []u64, row: Row) void {
    assert(words.len <= std.math.maxInt(u32));
    assert(row.start <= row.end);

    const range = word_range(words, row);

    assert(range.end <= words.len);

    @memset(words[range.start..range.end], 0);
}

fn bit_enter(words: []u64, row: Row, tokens: []const Token, index: u32) void {
    assert(index >= row.start);
    assert(index <= row.end);
    assert(words.len <= std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));

    var position = index;

    bit_set(words, position);

    for (row.start..row.end + 1) |_| {
        if (position >= row.end) break;
        if (tokens[position] != .segment_star) break;

        position += 1;
        bit_set(words, position);
    }

    assert(position <= row.end);
}

fn bits_close(words: []u64, row: Row, tokens: []const Token) void {
    assert(row.end <= tokens.len);
    assert(row.start <= row.end);
    assert(words.len <= std.math.maxInt(u32));

    for (row.start..row.end) |index| {
        if (!bit_test(words, @intCast(index))) continue;
        if (!tokens[index].skippable()) continue;

        const forward = index + 1;

        if (forward < row.end) assert(tokens[forward] != .segment_star);

        bit_set(words, @intCast(forward));
    }
}

fn bits_empty(words: []const u64, row: Row) bool {
    assert(words.len <= std.math.maxInt(u32));
    assert(row.start <= row.end);

    const range = word_range(words, row);

    assert(range.end <= words.len);

    for (words[range.start..range.end]) |word| {
        if (word != 0) return false;
    }

    return true;
}

fn brace_of(work: []const u8, span: Row, diagnostic: *Diagnostic) Error!Brace {
    assert(span.start <= span.end);
    assert(span.end <= work.len);

    var offset = span.start;
    var open: ?u32 = null;
    var depth: u32 = 0;

    for (0..variant_bytes_max + 1) |_| {
        if (offset >= span.end) break;

        const byte = work[offset];

        if (byte == '\\') {
            if (offset + 1 >= span.end) {
                diagnostic.offset = offset - span.start;

                return error.EscapeUnfinished;
            }

            offset += 2;

            continue;
        }

        switch (byte) {
            '{' => {
                depth += 1;

                if (depth > brace_depth_max) {
                    diagnostic.offset = offset - span.start;

                    return error.BraceTooDeep;
                }

                if (open == null) open = offset;
            },
            '}' => {
                depth -|= 1;

                if (depth == 0) {
                    const at = open orelse return .absent;
                    return .{ .present = .{ .end = offset, .start = at } };
                }
            },
            else => {},
        }

        offset += 1;
    }

    if (open) |at| {
        diagnostic.offset = at - span.start;

        return error.BraceUnclosed;
    }

    return .absent;
}

fn class(
    pattern: []const u8,
    start: u32,
    tokens: *bounded.ArrayType(Token),
    classes: *bounded.ArrayType(u8),
    diagnostic: *Diagnostic,
) Error!u32 {
    assert(start < pattern.len);
    assert(pattern[start] == '[');

    var offset = start + 1;
    var negated = false;

    if (offset < pattern.len) {
        const byte = pattern[offset];
        const negation = byte == '!' or byte == '^';

        if (negation) {
            negated = true;
            offset += 1;
        }
    }

    var bitmap: [class_bytes]u8 = @splat(0);

    const end = class_members(pattern, offset, &bitmap) orelse {
        diagnostic.offset = start;

        return error.ClassUnclosed;
    };

    if (classes.unused_capacity() < class_bytes) return error.ClassesExhausted;

    const at = classes.count();

    classes.push_slice(&bitmap);

    try push(tokens, .{ .class = .{ .negated = negated, .offset = at } });

    return end;
}

fn class_members(pattern: []const u8, start: u32, bitmap: *[class_bytes]u8) ?u32 {
    assert(pattern.len <= variant_bytes_max);
    assert(start <= pattern.len);

    var offset = start;
    var leading = true;

    for (0..variant_bytes_max + 1) |_| {
        if (offset >= pattern.len) return null;

        const byte = pattern[offset];

        if (byte == ']') {
            if (!leading) {
                assert(offset + 1 < std.math.maxInt(u32));

                return offset + 1;
            }
        }

        leading = false;

        const dashed = offset + 1 < pattern.len and pattern[offset + 1] == '-';
        const high: ?u8 = if (offset + 2 < pattern.len) pattern[offset + 2] else null;
        const ranged = dashed and high != null and high.? != ']';

        if (ranged) {
            set_range(bitmap, byte, high.?);
            offset += 3;

            continue;
        }

        set_bit(bitmap, byte);
        offset += 1;
    }

    unreachable;
}

fn escaped(
    pattern: []const u8,
    start: u32,
    tokens: *bounded.ArrayType(Token),
    diagnostic: *Diagnostic,
) Error!u32 {
    assert(start < pattern.len);
    assert(pattern[start] == '\\');

    if (start + 1 >= pattern.len) {
        diagnostic.offset = start;

        return error.EscapeUnfinished;
    }

    const returned = try literal(tokens, .{ .literal = pattern[start + 1] }, start + 1);

    assert(returned < std.math.maxInt(u32));

    return returned;
}

fn is_separator_literal(token: Token) bool {
    if (token == .class) assert(token.class.offset % class_bytes == 0);

    return switch (token) {
        .literal => |byte| byte == separator,
        .any, .class, .segment_star, .star, .tail_star => false,
    };
}

fn literal(tokens: *bounded.ArrayType(Token), token: Token, offset: u32) Error!u32 {
    assert(offset < variant_bytes_max);
    if (token == .class) assert(token.class.offset % class_bytes == 0);

    try push(tokens, token);

    assert(offset + 1 <= variant_bytes_max);

    return offset + 1;
}

fn push(tokens: *bounded.ArrayType(Token), token: Token) Error!void {
    if (tokens.full()) return error.BytesExhausted;
    if (token == .class) assert(token.class.offset % class_bytes == 0);

    tokens.push(token);

    assert(tokens.count() > 0);
}

fn rooted(run: []const Token, start: u32) Shape {
    assert(run.len <= std.math.maxInt(u32));
    assert(start < std.math.maxInt(u32));

    const tailed = run.len > 0 and run[run.len - 1] == .tail_star;

    if (tailed) {
        const fixed = split_fixed(run[0 .. run.len - 1], start) orelse return .general;
        return .{ .whole_prefix = fixed };
    }

    const fixed = split_fixed(run, start) orelse return .general;
    return .{ .whole = fixed };
}

fn run_length(run: Row) usize {
    assert(run.start <= run.end);

    return run.end - run.start;
}

fn set_bit(bitmap: *[class_bytes]u8, byte: u8) void {
    const slot = byte >> nibble_shift;
    const bit: u3 = @intCast(byte & nibble_low);

    assert(slot < class_bytes);

    bitmap[slot] |= @as(u8, 1) << bit;
}

fn set_range(bitmap: *[class_bytes]u8, low: u8, high: u8) void {
    if (low > high) return;

    for (@as(usize, low)..@as(usize, high) + 1) |byte| {
        set_bit(bitmap, @intCast(byte));
    }

    assert(is_member(bitmap, high));
}

fn split(
    work: *bounded.ArrayType(u8),
    pending: *bounded.ArrayType(Row),
    outer: Row,
    brace: Row,
) Error!void {
    assert(outer.start <= brace.start);
    assert(brace.end < outer.end);

    const open = brace.start;
    const close = brace.end;
    var cursor = open + 1;
    var depth: u32 = 0;
    var offset = open + 1;

    for (0..variant_bytes_max + 1) |_| {
        if (offset > close) break;

        const byte = work.get(offset);
        const boundary = offset == close or (byte == ',' and depth == 0);
        const nested_close = byte == '}' and offset != close;

        if (byte == '{') depth += 1;
        if (nested_close) depth -|= 1;

        if (boundary) {
            const at = work.count();

            try append_run(work, outer.start, open);
            try append_run(work, cursor, offset);
            try append_run(work, close + 1, outer.end);

            if (pending.full()) return error.VariantsExhausted;

            pending.push(.{ .end = work.count(), .start = at });
            cursor = offset + 1;
        }

        offset += 1;
    }
}

fn split_fixed(run: []const Token, base: u32) ?Fixed {
    assert(run.len <= std.math.maxInt(u32));
    assert(base < std.math.maxInt(u32));

    var split_at: ?u32 = null;

    for (run, 0..) |token, offset| {
        switch (token) {
            .any, .class, .literal => {},
            .star => {
                if (split_at != null) return null;

                split_at = @intCast(offset);
            },
            .segment_star, .tail_star => return null,
        }
    }

    const stop = base + @as(u32, @intCast(run.len));

    assert(stop >= base);
    if (split_at) |at| assert(at < run.len);

    const at = split_at orelse return .{
        .head = .{ .end = stop, .start = base },
        .star = false,
        .tail = .{ .end = stop, .start = stop },
    };

    return .{
        .head = .{ .end = base + at, .start = base },
        .star = true,
        .tail = .{ .end = stop, .start = base + at + 1 },
    };
}

fn star(
    pattern: []const u8,
    start: u32,
    tokens: *bounded.ArrayType(Token),
    diagnostic: *Diagnostic,
) Error!u32 {
    assert(start < pattern.len);
    assert(pattern[start] == '*');

    const doubled = start + 1 < pattern.len and pattern[start + 1] == '*';
    if (!doubled) return literal(tokens, .star, start);

    const before: u8 = if (start == 0) separator else pattern[start - 1];

    if (before != separator) {
        diagnostic.offset = start;

        return error.DoubleStarComponent;
    }

    if (start + 2 >= pattern.len) {
        try push(tokens, .tail_star);

        assert(tokens.count() > 0);

        return start + 2;
    }

    if (pattern[start + 2] == separator) {
        try push(tokens, .segment_star);

        assert(tokens.count() > 0);

        return start + 3;
    }

    diagnostic.offset = start;

    return error.DoubleStarComponent;
}

fn word_range(words: []const u64, row: Row) struct { start: usize, end: usize } {
    assert(row.start <= row.end);
    assert((row.end >> word_shift) < words.len);

    return .{ .start = row.start >> word_shift, .end = (row.end >> word_shift) + 1 };
}

fn words_for(token_count_max: u32) u32 {
    assert(token_count_max > 0);

    const bits = token_count_max + 2;
    return @max(1, @divCeil(bits, bits_per_word));
}
