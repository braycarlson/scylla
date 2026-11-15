const std = @import("std");
const assert = std.debug.assert;
const Language = @import("language.zig").Language;
const PRNG = @import("../testing/prng.zig");
const Tokens = @import("tokens.zig");
const fuzz = @import("../testing/fuzz.zig");
const fuzzing = @import("testing/fuzzing.zig");
const lex = @import("lex.zig").lex;

const Class = enum {
    bracket,
    byte,
    comment,
    number,
    operator,
    space,
    string,
    unicode,
    word,
};

const Weights = std.enums.EnumArray(Class, u32);

const fragments = std.enums.EnumArray(Class, []const []const u8).init(.{
    .bracket = &.{ "(", ")", "[", "]", "{", "}", "<", ">" },
    .byte = &.{},
    .comment = &.{ "//", "/*", "*/", "#", "--", "<!--", "///", "#!" },
    .number = &.{ "0", "1.5", "0x1f", "1e9", ".5", "1_000", "0b1", "7.", "0o7", "1n" },
    .operator = &.{
        "=", "==", "=>", "->", ":", "::", ";", ",",  ".",  "...", "?",  "!",  "+",  "-",  "*", "/",
        "%", "&",  "|",  "^",  "~", "@",  "$", "\\", "||", "&&",  ":=", "<-", "**", "?.",
    },
    .space = &.{ " ", "\t", "\n", "\r\n", "\r", "    ", "\x0b", "\x0c", "\n\n" },
    .string = &.{ "\"", "'", "`", "\"\"\"", "r#\"", "b'", "f\"", "${", "\\\\", "r\"" },
    .unicode = &.{
        "\u{00a0}",     "\u{2028}", "\u{feff}", "\u{00e4}", "\u{1F600}", "\xff", "\x00",
        "\xef\xbb\xbf", "\u{3000}",
    },
    .word = &.{
        "a",      "value", "fn",   "const", "if",      "else",   "def",    "class", "import",
        "return", "let",   "var",  "func",  "package", "pub",    "struct", "match", "async",
        "await",  "yield", "proc", "when",  "true",    "lambda", "for",    "while", "type",
    },
});

const event_count_default = 1_024;
const fragment_count_max = 256;
const source_bytes_max = fragment_count_max * 8;
const token_count_max = source_bytes_max * 4;

comptime {
    for (std.enums.values(Class)) |class| {
        for (fragments.get(class)) |fragment| {
            assert(fragment.len > 0);
            assert(fragment.len <= 8);
        }
    }
}

pub fn main(gpa: std.mem.Allocator, args: fuzz.Arguments) !void {
    if (args.events_max) |events_max| assert(events_max > 0);

    var prng: PRNG = .init(args.seed);
    const event_count = args.events_max orelse event_count_default;
    const source_buffer = try gpa.alloc(u8, source_bytes_max);
    defer gpa.free(source_buffer);

    var full: Tokens = try .init(gpa, token_count_max);
    defer full.deinit(gpa);

    var again: Tokens = try .init(gpa, token_count_max);
    defer again.deinit(gpa);

    for (0..event_count) |_| {
        const weights = weights_random(&prng);
        const source = source_generate(&prng, &weights, source_buffer);

        for (std.enums.values(Language)) |language| {
            if (!language.lexes()) continue;

            try check(gpa, &prng, language, source, &full, &again);
        }
    }
}

fn check(
    gpa: std.mem.Allocator,
    prng: *PRNG,
    language: Language,
    source: []const u8,
    full: *Tokens,
    again: *Tokens,
) !void {
    assert(source.len <= std.math.maxInt(u32));
    assert(language.lexes());

    full.clear();
    again.clear();

    try lex(.of(language), source, full);
    try lex(.of(language), source, again);

    const tokens = full.slice();

    fuzzing.tokens_check(source, tokens);
    assert(fuzzing.tokens_equal(tokens, again.slice()));

    if (tokens.len == 0) return;

    const budget = prng.range_inclusive(u32, 1, @intCast(tokens.len));
    var bounded: Tokens = try .init(gpa, budget);
    defer bounded.deinit(gpa);

    const lexed = bounded.lex(.of(language), source);

    const complete = if (lexed) |_| true else |err| switch (err) {
        error.Truncated => false,
    };

    if (complete) assert(budget == tokens.len);
    if (!complete) assert(budget < tokens.len);
    if (complete) assert(bounded.count() == tokens.len);
    if (!complete) assert(bounded.items.full());

    assert(fuzzing.tokens_equal(tokens[0..bounded.count()], bounded.slice()));
}

fn weights_random(prng: *PRNG) Weights {
    var weights: Weights = .initFill(0);
    var enabled: u32 = 0;

    for (std.enums.values(Class)) |class| {
        if (prng.boolean()) {
            weights.set(class, prng.range_inclusive(u32, 1, 100));
            enabled += 1;
        }
    }

    if (enabled == 0) weights.set(.word, 1);

    return weights;
}

fn source_generate(prng: *PRNG, weights: *const Weights, buffer: []u8) []const u8 {
    assert(buffer.len == source_bytes_max);

    const fragment_count = prng.int_inclusive(u32, fragment_count_max);
    var length: usize = 0;

    for (0..fragment_count) |_| {
        assert(length + 8 <= buffer.len);

        const class = class_weighted(prng, weights);
        const choices = fragments.get(class);

        if (choices.len == 0) {
            buffer[length] = prng.int(u8);
            length += 1;
        } else {
            const fragment = choices[prng.index(choices.len)];

            @memcpy(buffer[length..][0..fragment.len], fragment);
            length += fragment.len;
        }
    }

    assert(length <= buffer.len);

    return buffer[0..length];
}

fn class_weighted(prng: *PRNG, weights: *const Weights) Class {
    var total: u32 = 0;

    for (weights.values) |weight| total += weight;

    assert(total > 0);

    var pick = prng.int_inclusive(u32, total - 1);

    for (std.enums.values(Class)) |class| {
        const weight = weights.get(class);
        if (pick < weight) return class;

        pick -= weight;
    }

    unreachable;
}

test "the lexer fuzzer holds its invariants on a fixed seed" {
    try main(std.testing.allocator, .{ .seed = 92, .events_max = 64 });
}
