const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../stdx/bounded/array.zig").ArrayType;
const EventsType = @import("../syntax/tree.zig").EventsType;
const Language = @import("../syntax/language.zig").Language;
const Tokens = @import("../syntax/tokens.zig");
const TreeType = @import("../syntax/tree.zig").TreeType;
const brace = @import("brace.zig");
const grammars = @import("../syntax/grammars.zig");
const lex_into = @import("../syntax/raw.zig").lex_into;
const mask = @import("mask.zig");
const tag = @import("tag.zig");

test "terminated drops plain parens, owes semicolons and pairs a rebalanced chain" {
    const Parsed = ParsedType(grammars.javascript);
    const Pinned = PinnedType(grammars.javascript.Kind);
    const gpa = std.testing.allocator;
    const source = "let a = (b)\nconst m = d && (a && b && c)\n";
    const parsed = try gpa.create(Parsed);
    defer gpa.destroy(parsed);

    try parsed.init(gpa, .javascript, source);
    defer parsed.deinit(gpa);

    var stream = try mask.Terminators.init(gpa, 256, 1024);
    defer stream.deinit(gpa);

    const tokens = parsed.tokens.slice();

    try mask.terminated(
        grammars.javascript.Kind,
        &parsed.tree,
        source,
        tokens,
        &Pinned.rules,
        &stream,
    );

    const kinds = [_]u8{ 4, 3, 7, 3, 7, 4, 3, 7, 3, 7, 7, 3, 7, 3, 7, 7, 3, 7 };

    try std.testing.expectEqualStrings(
        "let a = b;\nconst m = d && (a && b) && c;\n",
        stream.source_slice(),
    );

    try std.testing.expectEqualSlices(u32, &.{ 11, 15 }, stream.nests_slice());
    try std.testing.expectEqual(kinds.len, stream.tokens_slice().len);

    for (stream.tokens_slice(), kinds) |token, kind| {
        try std.testing.expectEqual(kind, @backingInt(std.meta.activeTag(token.kind)));
    }

    for (stream.roles_slice()) |role| try std.testing.expectEqual(0, role);
}

test "tailed drops a lone closure block and breaks the arm ends" {
    const Parsed = ParsedType(grammars.rust);
    const Pinned = PinnedType(grammars.rust.Kind);
    const gpa = std.testing.allocator;

    const source = "fn main() {\n    let f = |a| { a + 1 };\n    match y {\n" ++
        "        Some(v) => value_one + value_two + value_three + value_four,\n" ++
        "        None => {}\n    }\n}\n";

    const parsed = try gpa.create(Parsed);
    defer gpa.destroy(parsed);

    try parsed.init(gpa, .rust, source);
    defer parsed.deinit(gpa);

    var stream = try mask.Terminators.init(gpa, 256, 1024);
    defer stream.deinit(gpa);

    const tokens = parsed.tokens.slice();
    const widths: mask.Widths = .{ .indent = 4, .line = 40 };

    try mask.tailed(
        grammars.rust.Kind,
        &parsed.tree,
        source,
        tokens,
        &Pinned.tails,
        widths,
        &stream,
    );

    const expected = "fn main() {\n    let f = |a| a + 1;\n    match y {\n" ++
        "        Some(v) => value_one + value_two + value_three + value_four,\n" ++
        "        None => {}\n    }\n}\n";

    try std.testing.expectEqualStrings(expected, stream.source_slice());
    try std.testing.expectEqual(37, stream.lists_slice().len);

    for (stream.lists_slice(), 0..) |listed, index| {
        const broken = index == 30 or index == 34;

        try std.testing.expectEqual(if (broken) brace.item_break else 0, listed);
    }

    for (stream.added_slice()) |code| try std.testing.expectEqual(0, code);

    const origins = stream.origins_slice()[0..8];

    try std.testing.expectEqualSlices(u32, &.{ 0, 3, 7, 8, 10, 16, 20, 22 }, origins);
}

test "marked flags node starts, blocks and lambdas" {
    const Parsed = ParsedType(grammars.rust);
    const gpa = std.testing.allocator;
    const source = "fn main() {\n    let f = |a| { a + 1 };\n}\n";
    const parsed = try gpa.create(Parsed);
    defer gpa.destroy(parsed);

    try parsed.init(gpa, .rust, source);
    defer parsed.deinit(gpa);

    var roles = try ArrayType(u16).init(gpa, 64);
    defer roles.deinit(gpa);

    try mask.marked(grammars.rust.Kind, &parsed.tree, parsed.tokens.slice(), &roles);

    const expected = [_]u16{ 2, 2, 0, 0, 3, 2, 2, 0, 6, 2, 0, 3, 2, 0, 2, 0, 0, 0 };

    try std.testing.expectEqualSlices(u16, &expected, roles.const_slice());
}

test "a stream reserved too small overflows instead of truncating" {
    const Parsed = ParsedType(grammars.javascript);
    const Pinned = PinnedType(grammars.javascript.Kind);
    const gpa = std.testing.allocator;
    const source = "let a = (b)\nconst m = d && (a && b && c)\n";
    const parsed = try gpa.create(Parsed);
    defer gpa.destroy(parsed);

    try parsed.init(gpa, .javascript, source);
    defer parsed.deinit(gpa);

    var stream = try mask.Terminators.init(gpa, 4, 1024);
    defer stream.deinit(gpa);

    const tokens = parsed.tokens.slice();

    const outcome = mask.terminated(
        grammars.javascript.Kind,
        &parsed.tree,
        source,
        tokens,
        &Pinned.rules,
        &stream,
    );

    try std.testing.expectError(error.Overflow, outcome);
}

fn ParsedType(comptime Module: type) type {
    return struct {
        events: EventsType(Module.Kind),
        parser: Module.Parser,
        raw: ArrayType(Module.Kind),
        tokens: Tokens,
        tree: TreeType(Module.Kind),

        const Parsed = @This();
        const element_count_max: u32 = 1024;

        fn init(
            parsed: *Parsed,
            gpa: std.mem.Allocator,
            language: Language,
            source: []const u8,
        ) !void {
            assert(language.lexes());
            assert(source.len <= std.math.maxInt(u32));

            try parsed.events.init(gpa, element_count_max * 4);
            errdefer parsed.events.deinit(gpa);

            parsed.raw = try .init(gpa, element_count_max);
            errdefer parsed.raw.deinit(gpa);

            parsed.tokens = try .init(gpa, element_count_max);
            errdefer parsed.tokens.deinit(gpa);

            parsed.tree = try .init(gpa, element_count_max * 2, element_count_max);
            errdefer parsed.tree.deinit(gpa);

            try lex_into(Module.Kind, .of(language), source, &parsed.tokens, &parsed.raw);

            const dialected = comptime @hasDecl(Module, "Dialect");

            const dialect = if (dialected) .{
                Module.Dialect.of_language(language).grammar(.module),
            } else .{};

            const tokens = parsed.tokens.slice();
            const raw = parsed.raw.const_slice();

            const structure = @call(.auto, Module.Parser.build, .{
                &parsed.parser,
                source,
                tokens,
                raw,
                &parsed.events,
                &parsed.tree,
            } ++ dialect);

            try std.testing.expectEqual(.complete, structure);
        }

        fn deinit(parsed: *Parsed, gpa: std.mem.Allocator) void {
            parsed.tree.deinit(gpa);
            parsed.tokens.deinit(gpa);
            parsed.raw.deinit(gpa);
            parsed.events.deinit(gpa);
        }
    };
}

fn PinnedType(comptime Kind: type) type {
    return struct {
        const rules: mask.RulesType(Kind) = .{
            .arrows = never,
            .bodiless = never,
            .bodies = never,
            .braced = never,
            .branches = never,
            .calls = never,
            .cases = never,
            .casts = never,
            .chains = never_chain,
            .defaults = never,
            .denies = never_pair,
            .drops = drops,
            .holes = never_hole,
            .imports = never_pair,
            .initializers = never_initializer,
            .invokes = never,
            .jsx = jsx,
            .jsx_wraps = never,
            .jumps = never_pair,
            .labels = never,
            .leads = never,
            .links = never,
            .lists = never,
            .mixes = mixes,
            .names = never,
            .nests = nests,
            .opens = never,
            .operators = never,
            .owes = owes,
            .parameters = never,
            .parens = parens,
            .passes = never,
            .patterns = never_pattern,
            .queries = never,
            .signs = signs,
            .soles = never,
            .spans = spans,
            .statements = statements,
            .tests = tests,
            .unaries = never,
            .updates = never,
            .wraps = wraps,
        };

        const tails: mask.TailsType(Kind) = .{
            .argued = never,
            .arms = arms,
            .attributes = never_triple,
            .bodies = bodies,
            .bounds = never,
            .call_width = 40,
            .chained = never,
            .compares = never,
            .flattens = never,
            .forces = never,
            .items = never,
            .keeps = never,
            .lambda = lambda,
            .lasts = never,
            .lines = never_pair,
            .literal = 30,
            .operands = never,
            .owes = never_pair,
            .width = 0,
            .wraps = wraps_tail,
        };

        fn named(kind: Kind, word: []const u8) bool {
            assert(word.len <= std.math.maxInt(u32));
            assert(kind.is_node());

            return std.ascii.findIgnoreCase(kind.name(), word) != null;
        }

        fn never(_: Kind) bool {
            return false;
        }

        fn never_pair(_: Kind, _: Kind) bool {
            return false;
        }

        fn never_triple(_: Kind, _: Kind, _: ?Kind) bool {
            return false;
        }

        fn never_initializer(_: Kind) mask.Initializer {
            return .none;
        }

        fn never_pattern(_: Kind) mask.Patterned {
            return .none;
        }

        fn never_hole(_: Kind) mask.Holed {
            return .plain;
        }

        fn never_chain(_: Kind) mask.Chained {
            return .none;
        }

        fn drops(_: Kind, _: Kind, _: ?Kind, heads: mask.Heads, _: bool) bool {
            return !heads.called;
        }

        fn jsx(_: Kind) tag.Jsx {
            return .none;
        }

        fn mixes(kind: Kind) bool {
            assert(kind.is_node());

            return named(kind, "binary") or named(kind, "logical");
        }

        fn nests(_: []const u8, _: []const u8, _: bool) bool {
            return false;
        }

        fn owes(kind: Kind, _: Kind) bool {
            assert(kind.is_node());

            return named(kind, "statement") or named(kind, "declaration");
        }

        fn parens(kind: Kind) bool {
            assert(kind.is_node());

            return named(kind, "paren");
        }

        fn signs(_: Kind, _: Kind, _: []const u8, _: []const u8, _: bool) ?bool {
            return null;
        }

        fn spans(_: Kind, _: Kind, _: ?Kind) bool {
            return true;
        }

        fn statements(kind: Kind) bool {
            assert(kind.is_node());

            return named(kind, "program") or named(kind, "block") or named(kind, "statement") or
                named(kind, "file") or named(kind, "source");
        }

        fn tests(_: Kind, _: Kind) ?bool {
            return null;
        }

        fn wraps(_: Kind, _: Kind, _: ?Kind, _: bool) bool {
            return false;
        }

        fn arms(kind: Kind) bool {
            assert(kind.is_node());

            return named(kind, "arm");
        }

        fn bodies(kind: Kind) u32 {
            assert(kind.is_node());

            return if (named(kind, "call")) 20 else 0;
        }

        fn lambda(kind: Kind) bool {
            assert(kind.is_node());

            return named(kind, "closure");
        }

        fn wraps_tail(kind: Kind) bool {
            assert(kind.is_node());

            return named(kind, "call") or named(kind, "binary");
        }
    };
}
