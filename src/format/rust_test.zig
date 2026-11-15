const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../stdx/bounded/array.zig").ArrayType;
const Buffer = @import("../stdx/bounded/buffer.zig");
const EventsType = @import("../syntax/tree.zig").EventsType;
const Formatter = @import("rust.zig").Formatter;
const FormatterError = @import("formatters.zig").FormatterError;
const Input = @import("rust.zig").Input;
const Kind = @import("../syntax/rust/kind.zig").Kind;
const Options = @import("print.zig").Options;
const Parser = @import("../syntax/rust/parse.zig").Parser;
const Span = @import("../stdx/bounded/span.zig");
const Structure = @import("../syntax/tree.zig").Structure;
const Token = @import("../syntax/token.zig");
const Tokens = @import("../syntax/tokens.zig");
const TreeType = @import("../syntax/tree.zig").TreeType;
const corpus = @import("../testing/corpus.zig");
const environment = @import("../testing/environment.zig");
const floor = @import("../testing/floor.zig");
const lex = @import("../syntax/lex.zig").lex;
const oracle = @import("../testing/oracle.zig");
const raw_of = @import("../syntax/raw.zig").raw_of;
const stripe = @import("../testing/stripe.zig");
const walk = @import("walk.zig");
const Events = EventsType(Kind);
const HeldError = FormatterError || error{Truncated};
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

        held.lexed_of(source);

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

            const text = std.mem.trimEnd(u8, token.text(source), ascii_whitespace);

            collected.appendAssumeCapacity(try lines_fed(arena, text));
        }

        assert(collected.items.len <= raw.len);

        return collected.items;
    }

    fn format(held: *Held, source: []const u8, out: *Buffer) HeldError!void {
        assert(source.len <= std.math.maxInt(u32));

        held.lexed_of(source);

        try raw_of(Kind, held.tokens.slice(), &held.raw);

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
            .options = options,
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
        var found: std.ArrayList(Kind) = try .initCapacity(arena, raw.len);

        for (raw) |kind| {
            if (kinds_skipped(kind)) continue;

            found.appendAssumeCapacity(kind);
        }

        assert(found.items.len <= raw.len);

        return found.items;
    }

    fn lexed_of(held: *Held, source: []const u8) void {
        assert(source.len <= std.math.maxInt(u32));

        held.tokens.clear();

        lex(.of(.rust), source, &held.tokens) catch |err| switch (err) {
            error.Truncated => assert(held.tokens.items.full()),
        };

        assert(held.tokens.count() <= token_count_max);
    }

    fn parsed(held: *Held, source: []const u8) Structure {
        const tokens = held.tokens.slice();
        const raw = held.raw.const_slice();

        assert(tokens.len == raw.len);
        assert(source.len <= std.math.maxInt(u32));

        return held.parser.build(source, tokens, raw, held.events, &held.tree);
    }

    fn range(
        held: *Held,
        source: []const u8,
        lines: walk.LineRange,
        out: *Buffer,
    ) HeldError!Span {
        assert(lines.first <= lines.last);
        assert(source.len <= std.math.maxInt(u32));

        held.lexed_of(source);

        try raw_of(Kind, held.tokens.slice(), &held.raw);

        const outcome = held.parsed(source);
        const input = held.input_of(source, outcome);

        assert(input.tokens.len == input.raw.len);

        return held.formatter.range(&input, lines, out);
    }

    fn words(held: *Held, arena: std.mem.Allocator, source: []const u8) ![]const []const u8 {
        assert(source.len <= std.math.maxInt(u32));

        held.lexed_of(source);

        const lexed = held.tokens.slice();
        var collected: std.ArrayList([]const u8) = try .initCapacity(arena, lexed.len);

        for (lexed) |token| {
            const structural = token.kind == .block_end or token.kind == .block_start or
                token.kind == .newline;

            if (structural) continue;
            if (token.length == 0) continue;

            collected.appendAssumeCapacity(word_of(token, source));
        }

        assert(collected.items.len <= lexed.len);
        assert(collected.capacity >= lexed.len);

        return collected.items;
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
        const before_kinds = try twice.held.kinds(allocator, fixture.source);
        const after_kinds = try twice.held.kinds(allocator, once);
        const before = try related(allocator, before_kinds);
        const after = try related(allocator, after_kinds);

        try require(terminated(before, after), "{s} lost a token", .{fixture.name});

        const comments_before = try twice.held.comments(allocator, fixture.source);
        const comments_after = try twice.held.comments(allocator, once);
        const joined_before = try std.mem.concat(allocator, u8, comments_before);
        const joined_after = try std.mem.concat(allocator, u8, comments_after);

        try expect_text(fixture.name, "lost a comment", joined_before, joined_after);

        const settled = try settles(&twice.held, once, &twice.second, fixture.name, worker.residue);

        if (settled) tally.settling += 1;
    }
};

const Fixture = corpus.File;
const ascii_whitespace = " \t\n\x0c\r";
const dump_variable = "SCYLLA_FORMAT_DUMP";
const element_count_max: u32 = 1 << 18;
const diagnostic_count_max: u32 = 1 << 12;
const event_count_max: u32 = 1 << 20;

const every_category = [_][]const u8{
    "rustfmt-item-ordering",
    "rustfmt-line-breaking",
    "rustfmt-macro-spacing",
};

const every_unsettled = [_][]const u8{ "reference-unstable", "scylla-unstable" };
const extension = ".rs";
const file_count_max: u32 = 1 << 20;
const fixture_count_min: u32 = 4;
const fixture_root = "tests/fixtures/rust";
const golden_root = "tests/fixtures/golden-rustfmt";
const node_count_max: u32 = 1 << 18;

const options: Options = .{
    .indent_width = Options.default.indent_width,
    .line_width = rustfmt_width,
    .tabs = Options.default.tabs,
};

const out_bytes_max: u32 = 1 << 22;
const path_bytes_max: u32 = 4096;
const residue_format_name = "residue-format-rust.json";
const residue_relations_name = "residue-relations-rust.json";
const rustfmt_width: u32 = 100;
const skipped_names = [_][]const u8{ "dedent", "indent", "newline" };
const source_bytes_max: u32 = 1 << 28;
const token_count_max: u32 = 1 << 18;

fn comments_equal(before: []const []const u8, after: []const []const u8) bool {
    if (before.len != after.len) return false;

    for (before, after) |one, two| {
        if (!std.mem.eql(u8, one, two)) return false;
    }

    return true;
}

fn corpus_selected(basename: []const u8) bool {
    assert(basename.len > 0);

    return std.mem.eql(u8, std.Io.Dir.path.extension(basename), extension);
}

fn ended(source: []const []const u8, printed: []const []const u8) bool {
    assert(source.len <= std.math.maxInt(u32));
    assert(printed.len <= std.math.maxInt(u32));

    var held: usize = 0;

    for (printed) |word| {
        if (held < source.len) {
            if (std.mem.eql(u8, source[held], word)) {
                held += 1;

                continue;
            }
        }

        if (std.mem.eql(u8, word, ";")) continue;
        return false;
    }

    return held == source.len;
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

fn RulesType(comptime T: type) type {
    return struct {
        ends: fn (T) bool,
        heads: fn (T) bool,
        opens: fn (T) bool,
        nests: fn (T) i32,
    };
}

fn imported(
    comptime T: type,
    arena: std.mem.Allocator,
    held: []const T,
    comptime rules: *const RulesType(T),
    comptime less_than: fn (void, T, T) bool,
) ![]const T {
    assert(held.len <= std.math.maxInt(u32));

    const Range = struct { start: usize, end: usize };

    const Context = struct {
        held: []const T,

        fn before(context: @This(), left: Range, right: Range) bool {
            assert(left.start <= left.end);
            assert(right.start <= right.end);
            assert(left.end <= context.held.len);

            const left_slice = context.held[left.start..left.end];
            const right_slice = context.held[right.start..right.end];
            const shared = @min(left_slice.len, right_slice.len);

            for (0..shared) |offset| {
                if (less_than({}, left_slice[offset], right_slice[offset])) return true;
                if (less_than({}, right_slice[offset], left_slice[offset])) return false;
            }

            return left_slice.len < right_slice.len;
        }
    };

    var found: std.ArrayList(T) = try .initCapacity(arena, held.len);
    var index: usize = 0;

    while (index < held.len) {
        var run: std.ArrayList(Range) = .empty;
        var scan = index;

        while (scan < held.len) {
            if (!rules.heads(held[scan])) break;

            const stop = statement_end(T, held, scan, rules.ends, rules.nests) orelse break;

            assert(stop > scan);

            if (!opened_at(T, held[scan..stop], rules)) break;

            try run.append(arena, .{ .start = scan, .end = stop });
            scan = stop;
        }

        if (run.items.len < 2) {
            found.appendAssumeCapacity(held[index]);
            index += 1;

            continue;
        }

        std.mem.sort(Range, run.items, Context{ .held = held }, Context.before);

        for (run.items) |range| found.appendSliceAssumeCapacity(held[range.start..range.end]);

        index = scan;
    }

    assert(found.items.len == held.len);

    return found.items;
}

fn kind_ends_statement(kind: Kind) bool {
    if (!kind.is_token()) return false;

    return kind == .semicolon;
}

fn kind_heads_import(kind: Kind) bool {
    if (!kind.is_token()) return false;

    return switch (kind) {
        .pound, .pub_keyword, .use_keyword => true,
        else => false,
    };
}

fn kind_is_use(kind: Kind) bool {
    if (!kind.is_token()) return false;

    return kind == .use_keyword;
}

fn kind_less_than(context: void, left: Kind, right: Kind) bool {
    _ = context;
    assert(left.is_token());
    assert(right.is_token());

    return @backingInt(left) < @backingInt(right);
}

fn kind_nested_less_than(context: void, left: Kind, right: Kind) bool {
    _ = context;
    assert(left.is_token());
    assert(right.is_token());

    const left_nest = nested_kind(left);
    const right_nest = nested_kind(right);
    if (left_nest != right_nest) return left_nest > right_nest;
    return std.mem.lessThan(u8, left.name(), right.name());
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

fn lines_fed(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    assert(text.len <= std.math.maxInt(u32));

    if (std.mem.find(u8, text, "\r\n") == null) return text;
    return std.mem.replaceOwned(u8, arena, text, "\r\n", "\n");
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

fn listed(arena: std.mem.Allocator, kinds: []const Kind) ![]const Kind {
    assert(kinds.len <= std.math.maxInt(u32));

    var found: std.ArrayList(Kind) = try .initCapacity(arena, kinds.len);

    for (kinds, 0..) |kind, index| {
        if (kind == .comma) {
            const next: ?Kind = if (index + 1 < kinds.len) kinds[index + 1] else null;

            const trailing = next != null and switch (next.?) {
                .brace_close, .bracket_close, .greater, .paren_close => true,
                else => false,
            };

            if (trailing) continue;
        }

        found.appendAssumeCapacity(kind);
    }

    assert(found.items.len <= kinds.len);

    return found.items;
}

fn listed_at(kinds: []const Kind, open: usize) ?usize {
    assert(kinds.len <= std.math.maxInt(u32));
    assert(open < std.math.maxInt(u32));

    var depth: i32 = 0;
    var index = open;

    while (index < kinds.len) {
        const held = kinds[index];

        if (held == .brace_close) {
            if (depth == 0) return index;

            depth -= 1;
            index += 1;

            continue;
        }

        if (held == .brace_open) {
            depth += 1;
            index += 1;

            continue;
        }

        const allowed = switch (held) {
            .as_keyword,
            .colon_colon,
            .comma,
            .crate_keyword,
            .identifier,
            .self_lower,
            .star,
            .super_keyword,
            .underscore,
            => true,
            else => false,
        };

        if (!allowed) return null;

        index += 1;
    }

    return null;
}

fn merged(arena: std.mem.Allocator, kinds: []const Kind) ![]const Kind {
    assert(kinds.len <= std.math.maxInt(u32));

    const bound = [_]Kind{
        .paren_close,
        .bracket_close,
        .pound,
        .bracket_open,
        .identifier,
        .paren_open,
    };

    var held: std.ArrayList(Kind) = try .initCapacity(arena, kinds.len);
    var index: usize = 0;

    while (index < kinds.len) {
        const matches_bound = index + bound.len <= kinds.len and
            std.mem.eql(Kind, kinds[index .. index + bound.len], &bound);

        if (matches_bound) {
            held.appendAssumeCapacity(.comma);
            index += bound.len;

            continue;
        }

        held.appendAssumeCapacity(kinds[index]);
        index += 1;
    }

    assert(held.items.len <= kinds.len);

    return held.items;
}

fn nested_kind(kind: Kind) i32 {
    assert(kind.is_token());

    return switch (kind) {
        .brace_open, .bracket_open, .paren_open => 1,
        .brace_close, .bracket_close, .paren_close => -1,
        else => 0,
    };
}

fn nested_word(word: []const u8) i32 {
    assert(word.len > 0);

    if (word.len != 1) return 0;

    return switch (word[0]) {
        '{', '[', '(' => 1,
        '}', ']', ')' => -1,
        else => 0,
    };
}

fn opened_at(comptime T: type, held: []const T, comptime rules: *const RulesType(T)) bool {
    assert(held.len <= std.math.maxInt(u32));

    var depth: i32 = 0;

    for (held) |element| {
        if (depth == 0) {
            if (rules.opens(element)) return true;

            if (!rules.heads(element)) {
                if (rules.nests(element) <= 0) return false;
            }
        }

        depth += rules.nests(element);
    }

    return false;
}

fn ordered(arena: std.mem.Allocator, kinds: []const Kind) ![]const Kind {
    assert(kinds.len <= std.math.maxInt(u32));

    var held: std.ArrayList(Kind) = try .initCapacity(arena, kinds.len);
    var index: usize = 0;

    while (index < kinds.len) {
        held.appendAssumeCapacity(kinds[index]);
        index += 1;

        if (kinds[index - 1] != .brace_open) continue;

        const close = listed_at(kinds, index) orelse continue;
        const run = try arena.dupe(Kind, kinds[index..close]);

        std.mem.sort(Kind, run, {}, kind_nested_less_than);
        held.appendSliceAssumeCapacity(run);

        index = close;
    }

    assert(held.items.len == kinds.len);

    return held.items;
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

    const step_merged = try merged(arena, kinds);
    const step_unwrapped = try unwrapped(arena, step_merged);
    const step_listed = try listed(arena, step_unwrapped);
    const step_ordered = try ordered(arena, step_listed);

    return imported(
        Kind,
        arena,
        step_ordered,
        &.{
            .ends = kind_ends_statement,
            .heads = kind_heads_import,
            .opens = kind_is_use,
            .nests = nested_kind,
        },
        kind_less_than,
    );
}

fn is_complete(result: HeldError!void) bool {
    if (std.meta.isError(result)) return false;

    return true;
}

fn is_refused(result: HeldError!void) bool {
    if (!std.meta.isError(result)) return false;

    result catch |err| switch (err) {
        error.OutputExhausted, error.Truncated => return false,
        error.SourceInvalid => return true,
    };

    return false;
}

fn outcome_name(result: HeldError!void) []const u8 {
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

fn statement_end(
    comptime T: type,
    held: []const T,
    from: usize,
    ends: fn (T) bool,
    nests: fn (T) i32,
) ?usize {
    assert(held.len <= std.math.maxInt(u32));
    assert(from < std.math.maxInt(u32));

    var depth: i32 = 0;
    var index = from;

    while (index < held.len) {
        depth += nests(held[index]);

        if (depth < 0) return null;

        if (depth == 0) {
            if (ends(held[index])) {
                assert(index + 1 < std.math.maxInt(u32));

                return index + 1;
            }
        }

        index += 1;
    }

    return null;
}

fn terminated(source: []const Kind, printed: []const Kind) bool {
    assert(source.len <= std.math.maxInt(u32));
    assert(printed.len <= std.math.maxInt(u32));

    var held: usize = 0;

    for (printed) |kind| {
        if (held < source.len) {
            if (source[held] == kind) {
                held += 1;

                continue;
            }
        }

        if (kind == .semicolon) continue;
        return false;
    }

    return held == source.len;
}

fn unwrapped(arena: std.mem.Allocator, kinds: []const Kind) ![]const Kind {
    assert(kinds.len <= std.math.maxInt(u32));

    const bare = try arena.alloc(bool, kinds.len);
    const cut = try arena.alloc(bool, kinds.len);

    @memset(bare, false);
    @memset(cut, false);

    var open: std.ArrayList(usize) = try .initCapacity(arena, kinds.len);

    for (kinds, 0..) |kind, index| {
        switch (nested_kind(kind)) {
            1 => open.appendAssumeCapacity(index),
            -1 => {
                if (open.pop()) |held| {
                    if (cut[held]) {
                        const after: ?Kind = if (index + 1 < kinds.len) kinds[index + 1] else null;
                        const received = after == .dot or after == .question;

                        cut[held] = !received;
                        cut[index] = !received;
                        bare[index] = bare[held];
                    }
                }
            },
            else => continue,
        }

        if (kind != .brace_open) continue;
        if (index == 0) continue;

        if (kinds[index - 1] == .fat_arrow) cut[index] = true;

        switch (kinds[index - 1]) {
            .@"or", .or_or => {
                cut[index] = true;
                bare[index] = true;
            },
            else => {},
        }
    }

    var held: std.ArrayList(Kind) = try .initCapacity(arena, kinds.len);

    for (kinds, 0..) |kind, index| {
        if (!cut[index]) {
            held.appendAssumeCapacity(kind);

            continue;
        }

        const next: ?Kind = if (index + 1 < kinds.len) kinds[index + 1] else null;
        const separated = next != null and (next.? == .comma or next.? == .semicolon);

        if (kind == .brace_close) {
            if (!bare[index]) {
                if (!separated) held.appendAssumeCapacity(.comma);
            }
        }
    }

    assert(held.items.len <= kinds.len);

    return held.items;
}

fn word_ends_statement(word: []const u8) bool {
    assert(word.len <= std.math.maxInt(u32));

    return std.mem.eql(u8, word, ";");
}

fn word_heads_import(word: []const u8) bool {
    assert(word.len <= std.math.maxInt(u32));

    return std.mem.eql(u8, word, "#") or std.mem.eql(u8, word, "pub") or
        std.mem.eql(u8, word, "use");
}

fn word_is_use(word: []const u8) bool {
    assert(word.len <= std.math.maxInt(u32));

    return std.mem.eql(u8, word, "use");
}

fn word_less_than(context: void, left: []const u8, right: []const u8) bool {
    _ = context;

    assert(left.len > 0);
    assert(right.len > 0);

    return std.mem.lessThan(u8, left, right);
}

fn word_of(token: Token, source: []const u8) []const u8 {
    assert(token.length > 0);
    assert(token.end() <= source.len);

    if (token.kind == .string) return "<string>";
    return token.text(source);
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
        const first = twice.held.format(fixture.source, &twice.first);

        try require(is_complete(first), "{s}", .{fixture.name});

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
        try held.format(fixture.source, &out);

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
        try held.format(fixture.source, &out);

        _ = arena.reset(.retain_capacity);

        const before = try held.comments(arena.allocator(), fixture.source);
        const after = try held.comments(arena.allocator(), out.const_slice());

        try require(comments_equal(before, after), "{s} lost a comment", .{fixture.name});
    }
}

test "the token relation reads an item ahead of an import run as no import" {
    const source = "#[derive(Debug)]\n" ++
        "pub struct Handle {\n" ++
        "    inner: u32,\n" ++
        "}\n" ++
        "\n" ++
        "use crate::runtime::task::JoinHandle;\n" ++
        "use crate::runtime::AutoBox;\n";

    const gpa = std.testing.allocator;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();

    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var out: Buffer = try .init(gpa, out_bytes_max);
    defer out.deinit(gpa);

    try held.format(source, &out);
    try std.testing.expect(!std.mem.eql(u8, source, out.const_slice()));

    const before_kinds = try held.kinds(arena.allocator(), source);
    const after_kinds = try held.kinds(arena.allocator(), out.const_slice());
    const before = try related(arena.allocator(), before_kinds);
    const after = try related(arena.allocator(), after_kinds);

    try std.testing.expect(terminated(before, after));
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
        try held.format(fixture.source, &out);
        try write_under(root, fixture.name, out.const_slice());
    }
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

        try held.format(fixture.source, &out);

        const golden = try read_under(gpa, golden_root, fixture.name);
        defer gpa.free(golden);

        const message = "diverges from rustfmt and no residue row names it";

        try expect_text(fixture.name, message, golden, out.const_slice());

        compared += 1;
    }

    try require(
        compared >= floor.fixture_format_rust,
        "the Rust fixtures lost a formatting: {d} compared, floor {d}",
        .{ compared, floor.fixture_format_rust },
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

        try held.format(source, &out);

        const golden = try read_under(gpa, golden_root, name);
        defer gpa.free(golden);

        const diverged = !std.mem.eql(u8, out.const_slice(), golden);

        try require(diverged, "{s} matches rustfmt and needs no residue row", .{name});
    }
}

test "a file that does not parse is refused" {
    const gpa = std.testing.allocator;
    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var out: Buffer = try .init(gpa, out_bytes_max);
    defer out.deinit(gpa);

    try std.testing.expectError(error.SourceInvalid, held.format("fn f( {\n", &out));
    try std.testing.expect(out.empty());
}

test "a block comment that never closes its nesting is refused" {
    const gpa = std.testing.allocator;
    const sources = [_][]const u8{ "/*/*/", "x/*/*/", "/* /*" };
    const closed = [_][]const u8{ "/* a */\n", "/* /* b */ */\n" };
    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var out: Buffer = try .init(gpa, out_bytes_max);
    defer out.deinit(gpa);

    for (sources) |source| {
        const outcome = held.format(source, &out);

        try require(is_refused(outcome), "{s} for \"{s}\"", .{ outcome_name(outcome), source });
    }

    for (closed) |source| {
        const outcome = held.format(source, &out);

        try require(is_complete(outcome), "{s} for \"{s}\"", .{ outcome_name(outcome), source });
    }
}

test "a range reads back the lines it names" {
    const gpa = std.testing.allocator;
    const source = "fn f() {\nlet x=1;\nlet _=x;\n}\n";
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

        const word_rules: *const RulesType([]const u8) = &.{
            .ends = word_ends_statement,
            .heads = word_heads_import,
            .opens = word_is_use,
            .nests = nested_word,
        };

        const before = try imported(
            []const u8,
            arena.allocator(),
            before_words,
            word_rules,
            word_less_than,
        );

        const after = try imported(
            []const u8,
            arena.allocator(),
            after_words,
            word_rules,
            word_less_than,
        );

        const message = "{s} split, joined, lost, or gained a word";

        try require(ended(before, after), message, .{fixture.name});
    }
}

test "a macro definitions matcher is written from the source and its body is laid out" {
    const source = "macro_rules! held {\n" ++
        "    ($a : ty, $b:expr) => {\n" ++
        "        #[doc=$b]\n" ++
        "        struct  S ( $a ) ;\n" ++
        "    };\n" ++
        "}\n";

    const wanted = "macro_rules! held {\n" ++
        "    ($a : ty, $b:expr) => {\n" ++
        "        #[doc=$b]\n" ++
        "        struct S($a);\n" ++
        "    };\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a sole argument that is a call parts inside that call" {
    const source = "fn a() -> io::Result<()> {\n" ++
        "    if held.status.is_error() {\n" ++
        "        Err(io::Error::from_raw_os_error(completion_token.status.as_usize()))\n" ++
        "    } else {\n" ++
        "        Ok(())\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "fn a() -> io::Result<()> {\n" ++
        "    if held.status.is_error() {\n" ++
        "        Err(io::Error::from_raw_os_error(\n" ++
        "            completion_token.status.as_usize(),\n" ++
        "        ))\n" ++
        "    } else {\n" ++
        "        Ok(())\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "an overflow stops at the callee that no longer fits the budget above it" {
    const source = "fn b() -> UnixDatagram {\n" ++
        "    UnixDatagram(Socket::from_inner(FromInner::from_inner(" ++
        "OwnedFd::from_raw_fd(fd))))\n" ++
        "}\n";

    const wanted = "fn b() -> UnixDatagram {\n" ++
        "    UnixDatagram(Socket::from_inner(FromInner::from_inner(\n" ++
        "        OwnedFd::from_raw_fd(fd),\n" ++
        "    )))\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "an overflow walks through a macro bracket the way it walks through a call" {
    const source = "fn f() {\n" ++
        "    {\n" ++
        "        let entrypoints = Arc::new(std::sync::RwLock::new(" ++
        "vec![PathBuf::from(\"app.component.ts\")]));\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "fn f() {\n" ++
        "    {\n" ++
        "        let entrypoints = Arc::new(std::sync::RwLock::new(vec![PathBuf::from(\n" ++
        "            \"app.component.ts\",\n" ++
        "        )]));\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a separator the source wrote past the last argument spells no column" {
    const a49: [49]u8 = @splat('a');

    const source = "fn c() {\n" ++
        "    let kind = E(format!(\"" ++ a49 ++ "\",));\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a macro definitions branch body is laid over lines however short it runs" {
    const source = "macro_rules! held {\n" ++
        "    ($a:expr) => { f($a) };\n" ++
        "}\n";

    const wanted = "macro_rules! held {\n" ++
        "    ($a:expr) => {\n" ++
        "        f($a)\n" ++
        "    };\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a macro branch body that is a block keeps the two braces welded" {
    const source = "macro_rules! held {\n" ++
        "    ($a:expr) => {{\n" ++
        "        f($a)\n" ++
        "    }};\n" ++
        "}\n";

    const wanted = "macro_rules! held {\n" ++
        "    ($a:expr) => {{ f($a) }};\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a macro definition holding a metavariable expression is written from the source" {
    const source = "macro_rules! held {\n" ++
        "    ($name:ident) => {\n" ++
        "        f!(one, ${ concat($name, _tail) } );\n" ++
        "    };\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a macro definition holding a comment past the width is written from the source" {
    const x96: [96]u8 = @splat('x');

    const source = "macro_rules! held {\n" ++
        "    ($a:expr) => {\n" ++
        "        // " ++ x96 ++ "\n" ++
        "        f( $a )\n" ++
        "    };\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "an attribute holding what no meta item holds is written from the source" {
    const source = "#[doc = concat!(\n" ++
        "    \"one\",\n" ++
        "    \"two\"\n" ++
        ")]\n" ++
        "pub fn held() {}\n";

    try expect_formatted(source, source);
}

test "an attribute holding a literal no meta item reads is written from the source" {
    const source = "#[foo(x  =  \"\"huh)]\n" ++
        "pub struct A;\n" ++
        "\n" ++
        "#[foo(x  =  1u8,  y  =  1abc)]\n" ++
        "pub struct B;\n" ++
        "\n" ++
        "#[foo(x  =  1u8,  y  =  1.5f32,  z  =  0x1fu8)]\n" ++
        "pub struct C;\n";

    const wanted = "#[foo(x  =  \"\"huh)]\n" ++
        "pub struct A;\n" ++
        "\n" ++
        "#[foo(x  =  1u8,  y  =  1abc)]\n" ++
        "pub struct B;\n" ++
        "\n" ++
        "#[foo(x = 1u8, y = 1.5f32, z = 0x1fu8)]\n" ++
        "pub struct C;\n";

    try expect_formatted(source, wanted);
}

test "a macro holding an interpolation is written from the source" {
    const source = "fn f() {\n" ++
        "    let a = quote!(__DeserializeWith #de_ty_generics);\n" ++
        "    let b = parse_quote!(#ident #ty_generics);\n" ++
        "    let c = quote!(&{#self_var.#member});\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a statement holding a macro the reference cannot read is formatted around it" {
    const source = "fn f() {\n" ++
        "    let x  =  foo(quote_spanned!(span=> a));\n" ++
        "    let y  =  match z {\n" ++
        "        A  =>  Some(quote_spanned!(span=> b)),\n" ++
        "        B  =>  2,\n" ++
        "    };\n" ++
        "}\n";

    const wanted = "fn f() {\n" ++
        "    let x = foo(quote_spanned!(span=> a));\n" ++
        "    let y = match z {\n" ++
        "        A => Some(quote_spanned!(span=> b)),\n" ++
        "        B => 2,\n" ++
        "    };\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "an arm whose sole argument is a macro the reference cannot read takes a block" {
    const source = "fn f() {\n" ++
        "    let x = match y {\n" ++
        "        StructTrait::SerializeStruct => Some(quote_spanned!(span=> " ++
        "_serde::ser::SerializeStruct::skip_fieldxx)),\n" ++
        "        StructTrait::SerializeStruct => Some(quote_spanned!(span=> " ++
        "_serde::ser::SerializeStruct::skip)),\n" ++
        "    };\n" ++
        "}\n";

    const wanted = "fn f() {\n" ++
        "    let x = match y {\n" ++
        "        StructTrait::SerializeStruct => {\n" ++
        "            Some(quote_spanned!(span=> _serde::ser::SerializeStruct::skip_fieldxx))\n" ++
        "        }\n" ++
        "        StructTrait::SerializeStruct => {\n" ++
        "            Some(quote_spanned!(span=> _serde::ser::SerializeStruct::skip))\n" ++
        "        }\n" ++
        "    };\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "an arm block whose open brace is written keeps its close and takes no comma" {
    const gpa = std.testing.allocator;
    const filler: [78]u8 = @splat('s');

    const source = "impl StructTrait {\n" ++
        "    fn skip_field(&self, span: Span) -> Option<TokenStream> {\n" ++
        "        match *self {\n" ++
        "            StructTrait::SerializeMap => None,\n" ++
        "            StructTrait::SerializeStructVariant => {\n" ++
        "                Some(\"" ++ filler ++ "\")\n" ++
        "            }\n" ++
        "        }\n" ++
        "    }\n" ++
        "}\n";

    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var out: Buffer = try .init(gpa, out_bytes_max);
    defer out.deinit(gpa);

    try held.format(source, &out);

    const printed = out.const_slice();

    try std.testing.expectEqual(std.mem.count(u8, source, "{"), std.mem.count(u8, printed, "{"));
    try std.testing.expectEqual(std.mem.count(u8, source, "}"), std.mem.count(u8, printed, "}"));
    try std.testing.expect(std.mem.find(u8, printed, "),\n            }") == null);
}

test "a literal carrying a suffix is formatted rather than refused" {
    const source = "fn f() {\n" ++
        "    let x  =  \"\"huh;\n" ++
        "    m!( 'a'x, b\"b\"y, r#\"c\"#z );\n" ++
        "}\n";

    const wanted = "fn f() {\n" ++
        "    let x = \"\"huh;\n" ++
        "    m!('a'x, b\"b\"y, r#\"c\"#z);\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a macro invocation the braces delimit is written from the source" {
    const source = "fn f() {\n" ++
        "    held! { a : b,  c }\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "an item the attribute holds out is written from the source" {
    const source = "fn f() {\n" ++
        "    #[rustfmt::skip]\n" ++
        "    let held = named(0,  1,  2,   3,  4,  5,   6,  7,  8,   9,  10, 11, " ++
        "12, 13, 14, 15,\n" ++
        "                     16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31);\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "an item no attribute holds out is written by the layout" {
    const source = "fn f() {\n" ++
        "    #[inline]\n" ++
        "    let held = named(0,  1);\n" ++
        "}\n";

    const wanted = "fn f() {\n" ++
        "    #[inline]\n" ++
        "    let held = named(0, 1);\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a definition the attribute holds out ends on its own brace" {
    const source = "#[rustfmt::skip]\n" ++
        "fn held(a:  u32) -> u32 {\n" ++
        "    1  +  2\n" ++
        "}\n" ++
        "\n" ++
        "fn after(b:  u32) {}\n";

    const wanted = "#[rustfmt::skip]\n" ++
        "fn held(a:  u32) -> u32 {\n" ++
        "    1  +  2\n" ++
        "}\n" ++
        "\n" ++
        "fn after(b: u32) {}\n";

    try expect_formatted(source, wanted);
}

test "a pattern writes its alternatives at the arm it belongs to" {
    const source = "fn held(value: Kind) -> Option<u32> {\n" ++
        "    match value {\n" ++
        "        Kind::ArithmeticShiftLeft\n" ++
        "        | Kind::ArithmeticShiftRight\n" ++
        "        | Kind::LogicalShiftRight\n" ++
        "        | Kind::CountLeadingZeros\n" ++
        "        | Kind::CountTrailingZeros => None,\n" ++
        "        _ => Some(0),\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a clause opens past the word ending a line and closes on the items separator" {
    const source = "pub trait Held {\n" ++
        "    /// The arguments the call takes.\n" ++
        "    type Args<'a>\n" ++
        "    where\n" ++
        "        Self: 'a;\n" ++
        "\n" ++
        "    /// The value the call answers with.\n" ++
        "    type Ret;\n" ++
        "}\n" ++
        "\n" ++
        "pub fn held<Scalar, Vector>(one: &dyn Fn(Vector) -> Scalar, " ++
        "two: &dyn Fn(Scalar) -> bool)\n" ++
        "where\n" ++
        "    Scalar: Copy + core::fmt::Debug + DefaultStrategy,\n" ++
        "    Vector: Into<[Scalar; 4]> + From<[Scalar; 4]> + Copy,\n" ++
        "{\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a branched expression wider than its own width parts at both braces" {
    const ones30: [30]u8 = @splat('1');
    const ones31: [31]u8 = @splat('1');

    const source = "fn held(c: bool) -> u32 {\n" ++
        "    let one = if c { " ++ ones30 ++ " } else { 2 };\n" ++
        "    let two = if c { " ++ ones31 ++ " } else { 2 };\n" ++
        "    one + two\n" ++
        "}\n";

    const wanted = "fn held(c: bool) -> u32 {\n" ++
        "    let one = if c { " ++ ones30 ++ " } else { 2 };\n" ++
        "    let two = if c {\n" ++
        "        " ++ ones31 ++ "\n" ++
        "    } else {\n" ++
        "        2\n" ++
        "    };\n" ++
        "    one + two\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "an attribute wider than its own width parts at the separators it holds" {
    const source = "#[unstable(feature = \"iter_macro\", issue = \"142269\", " ++
        "reason = \"generators unstab\")]\n" ++
        "fn a() {}\n" ++
        "#[unstable(feature = \"iter_macro\", issue = \"142269\", " ++
        "reason = \"generators unstabl\")]\n" ++
        "fn b() {}\n" ++
        "#[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd, Hash, " ++
        "Default, Serialize)]\n" ++
        "struct C;\n";

    const wanted = "#[unstable(feature = \"iter_macro\", issue = \"142269\", " ++
        "reason = \"generators unstab\")]\n" ++
        "fn a() {}\n" ++
        "#[unstable(\n" ++
        "    feature = \"iter_macro\",\n" ++
        "    issue = \"142269\",\n" ++
        "    reason = \"generators unstabl\"\n" ++
        ")]\n" ++
        "fn b() {}\n" ++
        "#[derive(Clone, Copy, Debug, Eq, PartialEq, Ord, PartialOrd, Hash, " ++
        "Default, Serialize)]\n" ++
        "struct C;\n";

    try expect_formatted(source, wanted);
}

test "an attribute the reference does not read stands however wide it runs" {
    const x31: [31]u8 = @splat('x');
    const y29: [29]u8 = @splat('y');

    const source = "#[foo(alpha = X" ++ x31 ++ ", beta = \"" ++ y29 ++ "\")]\n" ++
        "fn c() {}\n" ++
        "#[foo(\"Use of bat as a pager is disallowed in order to avoid infinite " ++
        "recursion prob1\")]\n" ++
        "fn d() {}\n";

    try expect_formatted(source, source);
}

test "a call wider than its own width parts at the separators it holds" {
    const a40: [40]u8 = @splat('a');
    const a41: [41]u8 = @splat('a');
    const b18: [18]u8 = @splat('b');

    const source = "fn t() {\n" ++
        "    held60(" ++ a40 ++ ", " ++ b18 ++ ");\n" ++
        "    held61(" ++ a41 ++ ", " ++ b18 ++ ");\n" ++
        "}\n";

    const wanted = "fn t() {\n" ++
        "    held60(" ++ a40 ++ ", " ++ b18 ++ ");\n" ++
        "    held61(\n" ++
        "        " ++ a41 ++ ",\n" ++
        "        " ++ b18 ++ ",\n" ++
        "    );\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a definition lays its own parameters out against the line" {
    const source = "fn t(ptr: *mut (), flags: u64, name_buf: *mut u8, filename: u8, " ++
        "held: u16) {}\n";

    try expect_formatted(source, source);
}

test "a run of imports is written in the order the language sorts them" {
    const source = "use zed::Zed;\n" ++
        "use crate::Alpha;\n" ++
        "use crate::alpha;\n" ++
        "use super::Beta;\n" ++
        "use self::Gamma;\n" ++
        "use std::fmt;\n" ++
        "\n" ++
        "use held::A;\n" ++
        "// a remark\n" ++
        "use later::B;\n" ++
        "use early::C;\n" ++
        "fn f() {}\n";

    const wanted = "use self::Gamma;\n" ++
        "use super::Beta;\n" ++
        "use crate::Alpha;\n" ++
        "use crate::alpha;\n" ++
        "use std::fmt;\n" ++
        "use zed::Zed;\n" ++
        "\n" ++
        "use held::A;\n" ++
        "// a remark\n" ++
        "use early::C;\n" ++
        "use later::B;\n" ++
        "fn f() {}\n";

    try expect_formatted(source, wanted);
}

test "a macro body and an item held out keep the order the source gave them" {
    const source = "cfg_if! {\n" ++
        "    if #[cfg(unix)] {\n" ++
        "        use zed::Zed;\n" ++
        "        use alpha::Alpha;\n" ++
        "    }\n" ++
        "}\n" ++
        "\n" ++
        "#[rustfmt::skip]\n" ++
        "mod held {\n" ++
        "    use zed::Zed;\n" ++
        "    use alpha::Alpha;\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a run of imports a comment or a string holds keeps the order the source gave it" {
    const held = "/*\n" ++
        "mod held {\n" ++
        "    use zed::Zed;\n" ++
        "    use alpha::Alpha;\n" ++
        "    /* nested */\n" ++
        "}\n" ++
        "*/\n" ++
        "const S: &str = \"\n" ++
        "use zed::Zed;\n" ++
        "use alpha::Alpha;\n" ++
        "\";\n" ++
        "const R: &str = \"macro_rules! {\";\n";

    const source = held ++ "use zed::Zed;\n" ++ "use alpha::Alpha;\n";
    const wanted = held ++ "use alpha::Alpha;\n" ++ "use zed::Zed;\n";

    try expect_formatted(source, wanted);
}

test "an import carries the comment ending its line and a comment running on ends the run" {
    const tail = "\n" ++
        "#[rustfmt::skip]\n" ++
        "use crate::ascii;\n" ++
        "pub(crate) use self::methods::E;\n" ++
        "use crate::error::Error; /* block\n" ++
        "still */\n" ++
        "use crate::a::B;\n";

    const source = "use zed::b; // about b\n" ++
        "use alpha::a;\n" ++
        "use beta::{c, /* inner */ d};\n" ++ tail;

    const wanted = "use alpha::a;\n" ++
        "use beta::{c, /* inner */ d};\n" ++
        "use zed::b; // about b\n" ++ tail;

    try expect_formatted(source, wanted);
}

test "a chain wider than its own width parts at every link it holds" {
    const x13: [13]u8 = @splat('x');
    const x10: [10]u8 = @splat('x');

    const source = "fn t() {\n" ++
        "    ab.inner.borrow_mut().entry(key).or_insert_with(Vec::new" ++ x13 ++ ");\n" ++
        "    abcde.inner.borrow_mut().entry(key).or_insert_with(Vec::new" ++ x10 ++ ");\n" ++
        "    self.slice[self.position..self.position + len].copy_from_slice(datax);\n" ++
        "}\n";

    const wanted = "fn t() {\n" ++
        "    ab.inner\n" ++
        "        .borrow_mut()\n" ++
        "        .entry(key)\n" ++
        "        .or_insert_with(Vec::new" ++ x13 ++ ");\n" ++
        "    abcde\n" ++
        "        .inner\n" ++
        "        .borrow_mut()\n" ++
        "        .entry(key)\n" ++
        "        .or_insert_with(Vec::new" ++ x10 ++ ");\n" ++
        "    self.slice[self.position..self.position + len].copy_from_slice(datax);\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a chain parted at its links keeps the tried call it ends on whole" {
    const source = "fn f() {\n" ++
        "    let value = match state.extra.mode {\n" ++
        "        SerMode::Json => match ob_type {\n" ++
        "            ObType::Tuple => {\n" ++
        "                let time = state.config.temporal_mode.time_to_json(" ++
        "value.py(), value.cast()?)?;\n" ++
        "            }\n" ++
        "        },\n" ++
        "    };\n" ++
        "}\n";

    const wanted = "fn f() {\n" ++
        "    let value = match state.extra.mode {\n" ++
        "        SerMode::Json => match ob_type {\n" ++
        "            ObType::Tuple => {\n" ++
        "                let time = state\n" ++
        "                    .config\n" ++
        "                    .temporal_mode\n" ++
        "                    .time_to_json(value.py(), value.cast()?)?;\n" ++
        "            }\n" ++
        "        },\n" ++
        "    };\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a literal wider than its own width parts at the separators it holds" {
    const ones6: [6]u8 = @splat('1');
    const twos6: [6]u8 = @splat('2');
    const x15: [15]u8 = @splat('x');

    const source = "fn t() -> Held {\n" ++
        "    let a = Held { one: " ++ ones6 ++ ", two: " ++ twos6 ++ " };\n" ++
        "    let b = Held { one: 1, ..Default::default() };\n" ++
        "    let c = Held { a: " ++ x15 ++ " };\n" ++
        "    Held { inner: sys::Condvar::new() }\n" ++
        "}\n";

    const wanted = "fn t() -> Held {\n" ++
        "    let a = Held {\n" ++
        "        one: " ++ ones6 ++ ",\n" ++
        "        two: " ++ twos6 ++ ",\n" ++
        "    };\n" ++
        "    let b = Held {\n" ++
        "        one: 1,\n" ++
        "        ..Default::default()\n" ++
        "    };\n" ++
        "    let c = Held { a: " ++ x15 ++ " };\n" ++
        "    Held {\n" ++
        "        inner: sys::Condvar::new(),\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a brace a word heads holds statements however wide they run" {
    const source = "fn t(held: Kind) -> bool {\n" ++
        "    if held.one && held.two && held.three && held.four && held.five {\n" ++
        "        return true;\n" ++
        "    }\n" ++
        "    let get = |size, lit| -> Vec<BString> { ngrams(size, lit).collect() };\n" ++
        "    get(1, \"x\").is_empty()\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a macro wider than a calls width parts at the separators it holds" {
    const source = "fn t() {\n" ++
        "    t!(first_argument_value_here, second_argument_value_here, " ++
        "third_argument_value_goes_here);\n" ++
        "    t!(first_argument_value_here, second_argument_value_her);\n" ++
        "}\n";

    const wanted = "fn t() {\n" ++
        "    t!(\n" ++
        "        first_argument_value_here,\n" ++
        "        second_argument_value_here,\n" ++
        "        third_argument_value_goes_here\n" ++
        "    );\n" ++
        "    t!(first_argument_value_here, second_argument_value_her);\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a macro holding a token stream stands however wide it runs" {
    const source = "fn t() {\n" ++
        "    thread_local!(static HELD: RefCell<u32> = RefCell::new(0); " ++
        "static O: Cell<u8> = Cell::new(1));\n" ++
        "    asm!(\"sfence.vma {}, {}\", in(reg) vaddr, in(reg) asid, " ++
        "options(nostack, preserves_flags));\n" ++
        "    check_it!(val: || {}, \"a name that carries on for a while " ++
        "so the whole runs past sixty\");\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a definitions parameters take the lines the width settles for them" {
    const a16: [16]u8 = @splat('a');
    const b16: [16]u8 = @splat('b');
    const c16: [16]u8 = @splat('c');
    const d16: [16]u8 = @splat('d');
    const e16: [16]u8 = @splat('e');

    const source = "fn joined(\n" ++
        "    aaa: u8,\n" ++
        "    bbb: u8,\n" ++
        ") {}\n" ++
        "fn parted(" ++ a16 ++ ": u8, " ++ b16 ++ ": u8, " ++ c16 ++
        ": u8, " ++ d16 ++ ": u8, " ++ e16 ++ ": u8) {}\n";

    const wanted = "fn joined(aaa: u8, bbb: u8) {}\n" ++
        "fn parted(\n" ++
        "    " ++ a16 ++ ": u8,\n" ++
        "    " ++ b16 ++ ": u8,\n" ++
        "    " ++ c16 ++ ": u8,\n" ++
        "    " ++ d16 ++ ": u8,\n" ++
        "    " ++ e16 ++ ": u8,\n" ++
        ") {}\n";

    try expect_formatted(source, wanted);
}

test "a value the source wrote under its assignment takes the line that holds it" {
    const source = "fn t() {\n" ++
        "    let held =\n" ++
        "        gathered(first_value);\n" ++
        "    let other =\n" ++
        "        gathered(first_value_here_long, second_value_here_long, " ++
        "third_value, fourth_value, fifth);\n" ++
        "}\n";

    const wanted = "fn t() {\n" ++
        "    let held = gathered(first_value);\n" ++
        "    let other = gathered(\n" ++
        "        first_value_here_long,\n" ++
        "        second_value_here_long,\n" ++
        "        third_value,\n" ++
        "        fourth_value,\n" ++
        "        fifth,\n" ++
        "    );\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a use tree is written tight and sorted at every brace it holds" {
    const source = "use { bstr::ByteVec, ignore::WalkBuilder };\n" ++
        "use crate::iter::{filter_map::FilterMap, filter::Filter, chain::Chain};\n" ++
        "pub use crate::{\n" ++
        "    color::{ColorSpecs, ColorError},\n" ++
        "    hyperlink::{\n" ++
        "        HyperlinkAlias, HyperlinkConfig, HyperlinkEnvironment,\n" ++
        "        HyperlinkFormat, HyperlinkFormatError, hyperlink_aliases,\n" ++
        "    },\n" ++
        "};\n" ++
        "fn t() {}\n";

    const wanted = "use crate::iter::{chain::Chain, filter::Filter, filter_map::FilterMap};\n" ++
        "pub use crate::{\n" ++
        "    color::{ColorError, ColorSpecs},\n" ++
        "    hyperlink::{\n" ++
        "        HyperlinkAlias, HyperlinkConfig, HyperlinkEnvironment, HyperlinkFormat,\n" ++
        "        HyperlinkFormatError, hyperlink_aliases,\n" ++
        "    },\n" ++
        "};\n" ++
        "use {bstr::ByteVec, ignore::WalkBuilder};\n" ++
        "fn t() {}\n";

    try expect_formatted(source, wanted);
}

test "a comment inside a chain keeps the level its links stand at" {
    const source = "fn main() {\n" ++
        "    PrettyPrinter::new()\n" ++
        "        .grid(true)\n" ++
        "        // The following line will be highlighted in the output:\n" ++
        "        .theme(\"1337\")\n" ++
        "        .print()\n" ++
        "        .unwrap();\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a macro the reference cannot read keeps the blanks the source gave it" {
    const source = "fn f() {\n" ++
        "    bar!(q : 1,  r : 2);\n" ++
        "    foo!(a,  b);\n" ++
        "}\n";

    const wanted = "fn f() {\n" ++
        "    bar!(q : 1,  r : 2);\n" ++
        "    foo!(a, b);\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a macro stream written under tabs lands at the columns they spell" {
    const source = "fn f() {\n" ++
        "    assert!(matches!(\n" ++
        "\t\terr,\n" ++
        "\t\tE::C(ref id) if id == \"n\"\n" ++
        "\t));\n" ++
        "}\n";

    const wanted = "fn f() {\n" ++
        "    assert!(matches!(\n" ++
        "        err,\n" ++
        "        E::C(ref id) if id == \"n\"\n" ++
        "    ));\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "an operator of two characters opens a continuation the way one of one does" {
    const source = "fn g(current_version: V, stored_version: V) -> bool {\n" ++
        "    current_version.major_number_value == stored_version.major_number_value\n" ++
        "        && current_version.minor_number_value == " ++
        "stored_version.minor_number_value\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "an await ends the operand the dot past it reads from" {
    const source = "async fn f(response: R) -> Result<(), E> {\n" ++
        "    Err(response.into_err().await.into())\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a sign opening a line carries on the value the line above left" {
    const source = "fn g() -> i32 {\n" ++
        "    let shift = a_significand_value_named_at_length.leading_zeros() as i32\n" ++
        "        - (implicit_bit_value_named_at_length << 3u32).leading_zeros() as i32;\n" ++
        "    shift\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a body the last bound shares its line with stands under the item" {
    const source = "fn held<T>(value: T) -> T\n" ++
        "where\n" ++
        "    T: Copy {\n" ++
        "    value\n" ++
        "}\n" ++
        "\n" ++
        "fn after() {}\n";

    try expect_formatted(source, source);
}

test "an item under a clause a body ended opens at the level the clause left" {
    const source = "impl Held {\n" ++
        "    fn run<T>(&self, value: T) -> T\n" ++
        "    where\n" ++
        "        T: Copy {\n" ++
        "        value\n" ++
        "    }\n" ++
        "\n" ++
        "    fn after(&self) {}\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a type the clause follows writes its value on a line of its own" {
    const source = "impl Aliased for Thing {\n" ++
        "    type Value = u32\n" ++
        "    where\n" ++
        "        Self: Sized;\n" ++
        "}\n";

    const wanted = "impl Aliased for Thing {\n" ++
        "    type Value\n" ++
        "        = u32\n" ++
        "    where\n" ++
        "        Self: Sized;\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a supertrait list stands one level under the colon that opens it" {
    const source = "pub trait Float:\n" ++
        "    Copy + PartialEq + PartialOrd + core::fmt::Debug + " ++
        "core::marker::Send + core::marker::Sync\n" ++
        "{\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a macro bracket answers to the width a call answers to" {
    const source = "fn v() {\n" ++
        "    let vec = vec![\n" ++
        "        Some(Box::new(42)),\n" ++
        "        Some(Box::new(24)),\n" ++
        "        None,\n" ++
        "        Some(Box::new(12)),\n" ++
        "    ];\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a generic list the source parted writes its elements one level in" {
    const source = "pub struct PeekMutHolder<\n" ++
        "    'a,\n" ++
        "    T,\n" ++
        "    #[unstable(feature = \"allocator_api\", issue = \"32838\")] " ++
        "A: Allocator + Clone = Global,\n" ++
        "> {\n" ++
        "    vec: &'a mut Vec<T, A>,\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a declarative macro definition writes its arms from the source" {
    const source = "pub macro wrap {\n" ++
        "    ($expr:expr) => {\n" ++
        "        builtin # wrap ( $expr )\n" ++
        "    },\n" ++
        "    ($expr:expr ; $ty:ty) => {\n" ++
        "        builtin # wrap ( $expr, $ty )\n" ++
        "    },\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a brace holding a block comment alone takes the blank the body owes" {
    const source = "fn h() {\n" ++
        "    match v {\n" ++
        "        Ok(_) => { /* fine */ }\n" ++
        "        Err(_) => { /* held */ }\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a filled list leaves the line the separator its last element owes" {
    const name_a: [15]u8 = @splat('a');
    const name_b: [15]u8 = @splat('b');
    const name_c: [15]u8 = @splat('c');
    const name_d: [15]u8 = @splat('d');
    const name_e: [15]u8 = @splat('e');
    const name_f: [16]u8 = @splat('f');
    const name_g: [15]u8 = @splat('g');

    const source = "use crate::held::{\n" ++
        "    " ++ name_a ++ ", " ++ name_b ++ ", " ++ name_c ++ ", " ++
        name_d ++ ", " ++ name_e ++ ",\n" ++
        "    " ++ name_f ++ ", " ++ name_g ++ ",\n" ++
        "};\n";

    try expect_formatted(source, source);
}

test "a match arm guard on a line of its own stands under the pattern" {
    const source = "fn h() {\n" ++
        "    match v {\n" ++
        "        Aaa(b)\n" ++
        "            if c(b) =>\n" ++
        "        {\n" ++
        "            d(b);\n" ++
        "        }\n" ++
        "        _ => {}\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a declarative macro matcher and its repeated body come from the source" {
    const source = "macro cfg_held(\n" ++
        "    $(#[cfg($c:meta)] $o:item)*\n" ++
        "    #[else] $f:item\n" ++
        ") {\n" ++
        "    $(#[cfg($c)] $o)*\n" ++
        "    #[cfg(not(any($($c),*)))] $f\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a body brace opening a line stands at the statements own level" {
    const source = "fn f() {\n" ++
        "    if a {\n" ++
        "        b();\n" ++
        "    } else\n" ++
        "    /* c */\n" ++
        "    {\n" ++
        "        d();\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a self import carrying an alias still sorts ahead of a name" {
    const source = "use p::{self as pm2, Span};\n";

    try expect_formatted(source, source);
}

test "a reference closes up against the lifetime it carries" {
    const source = "struct Bar<'a>(#[allow(unused)] &'a Foo);\n";

    try expect_formatted(source, source);
}

test "a continuation inside a bracket the run opened takes that brackets level" {
    const source = "fn f() {\n" ++
        "    let held = one\n" ++
        "        + two * (three_value_name_here\n" ++
        "            + four * (five_value_name_here + six_value_name_here + " ++
        "seven_value_name));\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a comment standing at a closing braces column takes that braces level" {
    const source = "fn f(a: u32) -> u32 {\n" ++
        "    if a > 2 {\n" ++
        "        one();\n" ++
        "        two();\n" ++
        "    // a remark\n" ++
        "    } else {\n" ++
        "        three();\n" ++
        "    }\n" ++
        "    a\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a chain link past a receiver closing on its own quote stands level with it" {
    const source = "fn f() -> String {\n" ++
        "    let held = \"\n" ++
        "one\n" ++
        "two\n" ++
        "    \"\n" ++
        "        .trim()\n" ++
        "        .to_string();\n" ++
        "    held\n" ++
        "}\n";

    const wanted = "fn f() -> String {\n" ++
        "    let held = \"\n" ++
        "one\n" ++
        "two\n" ++
        "    \"\n" ++
        "    .trim()\n" ++
        "    .to_string();\n" ++
        "    held\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "an arm guard is the base the operators under it step from" {
    const source = "fn f(held: Held) -> bool {\n" ++
        "    match held {\n" ++
        "        Held::Metadata(meta)\n" ++
        "            if meta.first_named_reading().is_file() && " ++
        "meta.second_named_reading() > 0\n" ++
        "                || meta.first_named_reading().is_block_device() =>\n" ++
        "        {\n" ++
        "            true\n" ++
        "        }\n" ++
        "        _ => false,\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a chain link past a receiver closing past its own text steps from it" {
    const source = "fn f() -> String {\n" ++
        "    let held = \"\n" ++
        "one\n" ++
        "two held\"\n" ++
        "        .trim()\n" ++
        "        .to_string();\n" ++
        "    held\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a macro matchers comment keeps the column the source gave it" {
    const source = "macro_rules! held {\n" ++
        "    (\n" ++
        "        $one:ident, // first\n" ++
        "        $two:ident,   // second\n" ++
        "        $three:ident, // third\n" ++
        "    ) => {};\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "an arrow inside a bracket that is no brace carries no continuation" {
    const source = "fn f() {\n" ++
        "    held!(\n" ++
        "        check,\n" ++
        "        (\n" ++
        "            one: u8 = a,\n" ++
        "        ) =>\n" ++
        "        wanted(one)\n" ++
        "    );\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a bracket the layout parts takes a level inside one that hugs" {
    const source = "fn f() {\n" ++
        "    if (a > 0\n" ++
        "        && held(\n" ++
        "            one_argument_value_here,\n" ++
        "            two_argument_value_here,\n" ++
        "            three_argument_value,\n" ++
        "        ) == b)\n" ++
        "        || c\n" ++
        "    {\n" ++
        "        run();\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a macro body holding a builtin prefix is written from the source" {
    const source = "pub macro deref($pat:pat) {\n" ++
        "    builtin # deref($pat)\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a tighter operator opening a line steps in from the looser one above" {
    const source = "fn f() -> bool {\n" ++
        "    alpha_one_two_three_four(one)\n" ++
        "        && beta_four_five_six_seven(two)\n" ++
        "            != gamma_seven_eight_nine_ten(three)\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a brace standing against a body brace takes no blank" {
    const source = "pub macro held() {{ core::held::run() }}\n";

    try expect_formatted(source, source);
}

test "an attributes own close ends no operand" {
    const source = "fn f() {\n" ++
        "    held(\n" ++
        "        #[cold]\n" ++
        "        || {\n" ++
        "            run();\n" ++
        "        },\n" ++
        "    );\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a pattern alternative inside a bracket keeps the arms own level" {
    const source = "fn f(v: E) -> u32 {\n" ++
        "    match v {\n" ++
        "        E::Let(\n" ++
        "            One(_, extracted_value_held)\n" ++
        "            | Two(_, _, extracted_value_held)\n" ++
        "            | Three(_, _, extracted_value_held),\n" ++
        "        ) => extracted_value_held,\n" ++
        "        _ => 0,\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a macro definitions body brace takes the blank the source wrote" {
    const source = "macro_rules! held{\n" ++
        "    ($t:ident) => {\n" ++
        "        struct $t;\n" ++
        "    };\n" ++
        "}\n";

    const wanted = "macro_rules! held {\n" ++
        "    ($t:ident) => {\n" ++
        "        struct $t;\n" ++
        "    };\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a type parameter list nested inside another steps again" {
    const source = "fn f() {\n" ++
        "    let _x: HeldOuterTypeNameThatIsVeryLongIndeed<\n" ++
        "        AlphaTypeNameThatIsAlsoQuiteLong,\n" ++
        "        InnerHeldTypeNameThatIsLong<\n" ++
        "        BetaTypeNameThatIsAlsoQuiteLong,\n" ++
        "        GammaTypeNameThatIsAlsoQuiteLong,\n" ++
        "    >,\n" ++
        "    > = held();\n" ++
        "}\n";

    const wanted = "fn f() {\n" ++
        "    let _x: HeldOuterTypeNameThatIsVeryLongIndeed<\n" ++
        "        AlphaTypeNameThatIsAlsoQuiteLong,\n" ++
        "        InnerHeldTypeNameThatIsLong<\n" ++
        "            BetaTypeNameThatIsAlsoQuiteLong,\n" ++
        "            GammaTypeNameThatIsAlsoQuiteLong,\n" ++
        "        >,\n" ++
        "    > = held();\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a chain a closure opens steps from the link that opened it" {
    const source = "fn f() {\n" ++
        "    let held = Some(format!(\n" ++
        "        \"{} \",\n" ++
        "        self.decorations_and_more_of_them\n" ++
        "            .iter()\n" ++
        "            .map(|d| d\n" ++
        "            .generate_the_decoration_for_this_line(line_number, true, self)\n" ++
        "            .text_of_the_generated_thing)\n" ++
        "            .collect::<Vec<String>>()\n" ++
        "            .join(\" \")\n" ++
        "    ));\n" ++
        "}\n";

    const wanted = "fn f() {\n" ++
        "    let held = Some(format!(\n" ++
        "        \"{} \",\n" ++
        "        self.decorations_and_more_of_them\n" ++
        "            .iter()\n" ++
        "            .map(|d| d\n" ++
        "                .generate_the_decoration_for_this_line(line_number, true, self)\n" ++
        "                .text_of_the_generated_thing)\n" ++
        "            .collect::<Vec<String>>()\n" ++
        "            .join(\" \")\n" ++
        "    ));\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a chain past a literal spelling its own lines stands level with it" {
    const source = "fn f() -> Result<u8, String> {\n    if a {\n        Ok(1)\n    } else " ++
        "{\n        Err(\"\\n\\n\\\n             couldn't determine visual stud" ++
        "io generator\\n\\\n             if VisualStudio is installed, however," ++
        " consider \\\n             running the appropriate vcvars script befor" ++
        "e building \\\n             this crate\\n\\\n             \"\n        " ++
        "    .to_string())\n    }\n}\n";

    const wanted = "fn f() -> Result<u8, String> {\n    if a {\n        Ok(1)\n    } else " ++
        "{\n        Err(\"\\n\\n\\\n             couldn't determine visual stud" ++
        "io generator\\n\\\n             if VisualStudio is installed, however," ++
        " consider \\\n             running the appropriate vcvars script befor" ++
        "e building \\\n             this crate\\n\\\n             \"\n        " ++
        ".to_string())\n    }\n}\n";

    try expect_formatted(source, wanted);
}

test "a jump ending a block laid over lines takes the separator the reference writes" {
    const source = "fn f() -> bool {\n" ++
        "    if a {\n" ++
        "        return false\n" ++
        "    }\n" ++
        "    loop {\n" ++
        "        break\n" ++
        "    }\n" ++
        "    true\n" ++
        "}\n";

    const wanted = "fn f() -> bool {\n" ++
        "    if a {\n" ++
        "        return false;\n" ++
        "    }\n" ++
        "    loop {\n" ++
        "        break;\n" ++
        "    }\n" ++
        "    true\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a jump ending a block standing on one line takes no separator" {
    const source = "fn f(a: bool) -> u32 {\n" ++
        "    if a { return 1 } else { return 2 }\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a braced macro body moves to the column the emitter stands at" {
    const source = "fn f() {\n" ++
        "    held! {\n" ++
        "\t\t\tlet a = 1;\n" ++
        "\t\t}\n" ++
        "}\n";

    const wanted = "fn f() {\n" ++
        "    held! {\n" ++
        "        let a = 1;\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a macro definition holding a repetition keeps the lines the source wrote" {
    const source = "macro_rules! held {\n" ++
        "  ($($a:expr),+) => {\n" ++
        "     f($($a),+)\n" ++
        "  };\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a header the source parted comes back whole where it fits" {
    const source = "fn f() {\n" ++
        "    if aaa(x)\n" ++
        "        && bbb(y)\n" ++
        "    {\n" ++
        "        g();\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "fn f() {\n" ++
        "    if aaa(x) && bbb(y) {\n" ++
        "        g();\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a let chain keeps the lines the source parted it on" {
    const source = "fn f() {\n" ++
        "    if let Some(c) = d()\n" ++
        "        && c.is_ok()\n" ++
        "    {\n" ++
        "        g();\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a let binding past the single line else width lays its else block over lines" {
    const a17: [17]u8 = @splat('a');
    const a18: [18]u8 = @splat('a');

    const source = "fn f() {\n" ++
        "    let Some(" ++ a17 ++ ") = q() else { return };\n" ++
        "    let Some(" ++ a18 ++ ") = q() else { return };\n" ++
        "}\n";

    const wanted = "fn f() {\n" ++
        "    let Some(" ++ a17 ++ ") = q() else { return };\n" ++
        "    let Some(" ++ a18 ++ ") = q() else {\n" ++
        "        return;\n" ++
        "    };\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "an else a branch opens is no let binding however wide the statement runs" {
    const source = "fn f() {\n" ++
        "    let prefix = if self.has_fields { \", \" } else { \" { \" };\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a match arm body of one expression loses the braces around it" {
    const source = "fn f() {\n" ++
        "    match x {\n" ++
        "        X => {\n" ++
        "            g(a)\n" ++
        "        }\n" ++
        "        Y => {}\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "fn f() {\n" ++
        "    match x {\n" ++
        "        X => g(a),\n" ++
        "        Y => {}\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a match arm body that carries a statement keeps its braces" {
    const source = "fn f() {\n" ++
        "    match x {\n" ++
        "        X => {\n" ++
        "            g(a);\n" ++
        "        }\n" ++
        "        Y => {}\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a chain past its width parts the block brace it stands under" {
    const source = "impl A {\n" ++
        "    fn f(&mut self, index: usize) -> &mut K {\n" ++
        "        unsafe { holder.as_leaf_mut().keys.as_mut_slice()." ++
        "get_unchecked_mut(index) }\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "impl A {\n" ++
        "    fn f(&mut self, index: usize) -> &mut K {\n" ++
        "        unsafe {\n" ++
        "            holder\n" ++
        "                .as_leaf_mut()\n" ++
        "                .keys\n" ++
        "                .as_mut_slice()\n" ++
        "                .get_unchecked_mut(index)\n" ++
        "        }\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a value a comment stands ahead of is written from the source" {
    const source = "fn f() {\n" ++
        "    let held =\n" ++
        "        // a remark the reference keeps where the source put it\n" ++
        "        one.two().three().four().five().six().seven().eight().nine().ten();\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a call past its width parts at the innermost bracket its sole argument opens" {
    const source = "impl A {\n" ++
        "    fn f() -> Res {\n" ++
        "        Err(io::const_error!(io::ErrorKind::Unsupported, " ++
        "\"unavailable on the platform\"))\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "impl A {\n" ++
        "    fn f() -> Res {\n" ++
        "        Err(io::const_error!(\n" ++
        "            io::ErrorKind::Unsupported,\n" ++
        "            \"unavailable on the platform\"\n" ++
        "        ))\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a closure standing as a calls sole argument opens no bracket the width parts" {
    const source = "fn f(b: &mut B) {\n" ++
        "    b.iter(|| assert_eq!(2, set.matches(SEARCHED_FOR_TEXT).iter().count()));\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a closure body of one expression loses the block around it" {
    const source = "fn f() {\n" ++
        "    let h = q.map(|v| {\n" ++
        "        g(v)\n" ++
        "    });\n" ++
        "}\n";

    const wanted = "fn f() {\n" ++
        "    let h = q.map(|v| g(v));\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a closure written inside a macro keeps the block the source gave it" {
    const source = "fn f() {\n" ++
        "    assert!(e.any(|v| {\n" ++
        "        g(v)\n" ++
        "    }));\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a separator a nested macro keeps spells a column of the list around it" {
    const source = "fn f() {\n" ++
        "    assert_eq!(\n" ++
        "        parser(\"[ab]\").parse(),\n" ++
        "        Ok(Ast::class_bracketed(ast::ClassBracketed {\n" ++
        "            span: span(0..4),\n" ++
        "            negated: false,\n" ++
        "            kind: union(\n" ++
        "                span(1..3),\n" ++
        "                vec![lit(span(1..2), 'a'), lit(span(2..3), 'b'),]\n" ++
        "            ),\n" ++
        "        }))\n" ++
        "    );\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a struct variant an attributed enum holds stays over lines whichever way it came" {
    const wanted = "enum Enum {\n" ++
        "    Unit,\n" ++
        "    One(i32),\n" ++
        "    Map {\n" ++
        "        a: i32,\n" ++
        "        b: i32,\n" ++
        "    },\n" ++
        "    #[serde(skip_serializing)]\n" ++
        "    SkippedUnit,\n" ++
        "}\n";

    const joined = "enum Enum {\n" ++
        "    Unit,\n" ++
        "    One(i32),\n" ++
        "    Map { a: i32, b: i32 },\n" ++
        "    #[serde(skip_serializing)]\n" ++
        "    SkippedUnit,\n" ++
        "}\n";

    try expect_formatted(wanted, wanted);
    try expect_formatted(joined, wanted);
}

test "a chain ending a parted list leaves the column its separator owes" {
    const source = "fn f() {\n" ++
        "    for (bindless_index, unprepared_binding_resource) in " ++
        "unprepared_bind_group.iter() {\n" ++
        "        match x {\n" ++
        "            Some(y) => {\n" ++
        "                if z {\n" ++
        "                    debug_assert!(\n" ++
        "                        pre_existing_slot\n" ++
        "                            .is_none_or(|pre_existing_slot| " ++
        "*pre_existing_slot == slot)\n" ++
        "                    );\n" ++
        "                    pre_existing_slot.is_none()\n" ++
        "                }\n" ++
        "            }\n" ++
        "        }\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a value a narrower source parted joins its equals line where it fits flat" {
    const source = "impl T {\n" ++
        "    fn case_fold_char(&self, span: Span, c: char) -> Result<Option<Hir>> {\n" ++
        "        if self.flags().unicode() {\n" ++
        "            let mut cls =\n" ++
        "                hir::ClassUnicode::new(vec![hir::ClassUnicodeRange::new(\n" ++
        "                    c, c,\n" ++
        "                )]);\n" ++
        "            cls\n" ++
        "        }\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "impl T {\n" ++
        "    fn case_fold_char(&self, span: Span, c: char) -> Result<Option<Hir>> {\n" ++
        "        if self.flags().unicode() {\n" ++
        "            let mut cls = " ++
        "hir::ClassUnicode::new(vec![hir::ClassUnicodeRange::new(c, c)]);\n" ++
        "            cls\n" ++
        "        }\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a closure a macro holds past its budget hangs and parts the call it returns" {
    const flat = "fn f(b: &mut test::Bencher) {\n" ++
        "    bench_server!(b, (\"content-length\", \"1000000\"), || body(&[b'x'; 1_000_000]))\n" ++
        "}\n";

    const wanted = "fn f(b: &mut test::Bencher) {\n" ++
        "    bench_server!(b, (\"content-length\", \"1000000\"), || body(\n" ++
        "        &[b'x'; 1_000_000]\n" ++
        "    ))\n" ++
        "}\n";

    try expect_formatted(flat, wanted);

    const stacked = "fn f() {\n" ++
        "    {\n" ++
        "        assert_pending!(poll!(std::future::poll_fn(|cx| poll_read_ready_function(\n" ++
        "            afd_a_2_long,\n" ++
        "            cx\n" ++
        "        ))));\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(stacked, stacked);
}

test "a closure block a parting chain moves drops at the column the closure lands at" {
    const head = "fn contained_owned_self_method(item_list: Option<ast::AssocItemList>) " ++
        "-> bool {\n";

    const source = head ++
        "    item_list.into_iter().flat_map(|assoc_item_list| assoc_item_list.assoc_items())" ++
        ".any(|item| {\n" ++
        "        match item {\n" ++
        "            AssocItem::Fn(f) => {\n" ++
        "                has_owned_self(&f) && where_clause_sized(f.where_clause()).is_none()\n" ++
        "            }\n" ++
        "            _ => false,\n" ++
        "        }\n" ++
        "    })\n" ++
        "}\n";

    const wanted = head ++
        "    item_list\n" ++
        "        .into_iter()\n" ++
        "        .flat_map(|assoc_item_list| assoc_item_list.assoc_items())\n" ++
        "        .any(|item| match item {\n" ++
        "            AssocItem::Fn(f) => {\n" ++
        "                has_owned_self(&f) && where_clause_sized(f.where_clause()).is_none()\n" ++
        "            }\n" ++
        "            _ => false,\n" ++
        "        })\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a chain an assertion macro roots answers to the chain width with its name" {
    const source = "fn f() {\n" ++
        "    task.enter(|cx, _| {\n" ++
        "        assert_eq!(\n" ++
        "            io::ErrorKind::Other,\n" ++
        "            assert_ready!(pin!(framed).poll_next(cx)).unwrap().unwrap_err().kind()\n" ++
        "        )\n" ++
        "    });\n" ++
        "}\n";

    const wanted = "fn f() {\n" ++
        "    task.enter(|cx, _| {\n" ++
        "        assert_eq!(\n" ++
        "            io::ErrorKind::Other,\n" ++
        "            assert_ready!(pin!(framed).poll_next(cx))\n" ++
        "                .unwrap()\n" ++
        "                .unwrap_err()\n" ++
        "                .kind()\n" ++
        "        )\n" ++
        "    });\n" ++
        "}\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "a closure a macro holds past its budget hangs and parts its chain" {
    const head = "fn f() {\n    {\n";
    const tail = "    }\n}\n";

    const wanted = head ++
        "        assert_pending!(poll!(std::future::poll_fn(|cx| afd_a_2\n" ++
        "            .as_ref()\n" ++
        "            .poll_read_ready(cx))));\n" ++ tail;

    const flat = head ++
        "        assert_pending!(poll!(std::future::poll_fn(|cx| afd_a_2.as_ref()." ++
        "poll_read_ready(cx))));\n" ++ tail;

    const parted = head ++
        "        assert_pending!(poll!(std::future::poll_fn(\n" ++
        "            |cx| afd_a_2.as_ref().poll_read_ready(cx)\n" ++
        "        )));\n" ++ tail;

    try expect_formatted(wanted, wanted);
    try expect_formatted(flat, wanted);
    try expect_formatted(parted, wanted);

    const second = head ++
        "        assert_pending!(poll!(std::future::poll_fn(x, |cx| afd_a_2\n" ++
        "            .as_ref()\n" ++
        "            .poll_read_ready(cx))));\n" ++ tail;

    try expect_formatted(second, second);

    const linked = head ++
        "        assert_pending!(poll!(std::future::poll_fn(\n" ++
        "            |cx| afd_a_2_long_name_here_x.poll_read_ready(cx)\n" ++
        "        )));\n" ++ tail;

    try expect_formatted(linked, linked);
}

test "a bracket holding one chain parts where its callee is no shorter than the indent" {
    const a15: [15]u8 = @splat('a');

    const source = "fn f() {\n" ++
        "    assert!(result.err().unwrap().to_string().contains(\"" ++ a15 ++ "\"));\n" ++
        "    qqq(result.err().unwrap().to_string().contains(\"" ++ a15 ++ "\"));\n" ++
        "}\n";

    const wanted = "fn f() {\n" ++
        "    assert!(\n" ++
        "        result\n" ++
        "            .err()\n" ++
        "            .unwrap()\n" ++
        "            .to_string()\n" ++
        "            .contains(\"" ++ a15 ++ "\")\n" ++
        "    );\n" ++
        "    qqq(result\n" ++
        "        .err()\n" ++
        "        .unwrap()\n" ++
        "        .to_string()\n" ++
        "        .contains(\"" ++ a15 ++ "\"));\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a value the equals line cannot hold moves whole to the line under it" {
    const a15: [15]u8 = @splat('a');

    const source = "fn f() {\n" ++
        "    let held = " ++ a15 ++ " + " ++ a15 ++ " + " ++ a15 ++ " + " ++ a15 ++
        " + " ++ a15 ++ ";\n" ++
        "}\n";

    const wanted = "fn f() {\n" ++
        "    let held =\n" ++
        "        " ++ a15 ++ " + " ++ a15 ++ " + " ++ a15 ++ " + " ++ a15 ++ " + " ++
        a15 ++ ";\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a branch the source parted comes back whole where it spells fifty columns" {
    const source = "fn f() -> u8 {\n" ++
        "    let held = if wide {\n" ++
        "        a\n" ++
        "    } else {\n" ++
        "        b\n" ++
        "    };\n" ++
        "}\n";

    const wanted = "fn f() -> u8 {\n" ++
        "    let held = if wide { a } else { b };\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a branch standing alone in a match arm block keeps its lines" {
    const source = "fn f() -> u8 {\n" ++
        "    match x {\n" ++
        "        Err(root) => {\n" ++
        "            if len > 0 {\n" ++
        "                Ok(None)\n" ++
        "            } else {\n" ++
        "                Err(root)\n" ++
        "            }\n" ++
        "        }\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a match arm body the layout parts still writes its head on the arrow line" {
    const source = "fn f() {\n" ++
        "    match x {\n" ++
        "        Some(v) => {\n" ++
        "            Ok(Held {\n" ++
        "                value_of_the_thing: v,\n" ++
        "                mark: 1,\n" ++
        "            })\n" ++
        "        }\n" ++
        "        Y => {}\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "fn f() {\n" ++
        "    match x {\n" ++
        "        Some(v) => Ok(Held {\n" ++
        "            value_of_the_thing: v,\n" ++
        "            mark: 1,\n" ++
        "        }),\n" ++
        "        Y => {}\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a line opening on a body brace stands at the headers own level" {
    const source = "pub trait Int:\n" ++
        "    Sized\n" ++
        "    + Clone\n" ++
        "    + CastInto<i16>\n" ++
        "{\n" ++
        "    const ZERO: Self;\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a definition header carries on past the word its own trait stands before" {
    const source = "impl<'a, P: Pattern<Searcher<'a>: DoubleEndedSearcher<'a>>> " ++
        "DoubleEndedIterator\n" ++
        "    for SplitInclusive<'a, P>\n" ++
        "{\n" ++
        "    fn f() {}\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a use tree wider than the line it answers to is laid over lines" {
    const a88: [88]u8 = @splat('a');
    const source = "use crate::io::{self, Write, " ++ a88 ++ "};\n";

    const wanted = "use crate::io::{\n" ++
        "    self, Write,\n" ++
        "    " ++ a88 ++ ",\n" ++
        "};\n";

    try expect_formatted(source, wanted);
}

test "a closure body laid over lines takes the block the reference writes" {
    const source = "fn f(b: &mut B) {\n" ++
        "    b.iter(|| CHARS.iter().cycle().take(10_000)." ++
        "map(|c| black_box(c).to_digit(2)).min())\n" ++
        "}\n";

    const wanted = "fn f(b: &mut B) {\n" ++
        "    b.iter(|| {\n" ++
        "        CHARS\n" ++
        "            .iter()\n" ++
        "            .cycle()\n" ++
        "            .take(10_000)\n" ++
        "            .map(|c| black_box(c).to_digit(2))\n" ++
        "            .min()\n" ++
        "    })\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a closure body of one link answers to the line and takes no block" {
    const source = "fn f() {\n" ++
        "    held(|mem| mem.with_metadata_of(ptr::from_ref(for_value) as *const Inner<T>));\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a chain of one link the source parted comes back whole" {
    const source = "fn f() {\n" ++
        "    writeln!(out, \"a line of prose\")\n" ++
        "        .unwrap();\n" ++
        "}\n";

    const wanted = "fn f() {\n" ++
        "    writeln!(out, \"a line of prose\").unwrap();\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a chain of two links past the chain width keeps the lines it was given" {
    const source = "fn f() {\n" ++
        "    held\n" ++
        "        .with_a_name_of_its_own(alpha)\n" ++
        "        .and_another_name_here(bravo);\n" ++
        "}\n";

    const wanted = "fn f() {\n" ++
        "    held.with_a_name_of_its_own(alpha)\n" ++
        "        .and_another_name_here(bravo);\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a header that fits without its brace joins and leaves the brace alone" {
    const a41: [41]u8 = @splat('a');
    const b42: [42]u8 = @splat('b');

    const source = "fn f() {\n" ++
        "    if " ++ a41 ++ "(x)\n" ++
        "        && " ++ b42 ++ "(y)\n" ++
        "    {\n" ++
        "        g();\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "fn f() {\n" ++
        "    if " ++ a41 ++ "(x) && " ++ b42 ++ "(y)\n" ++
        "    {\n" ++
        "        g();\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "an enum variants own brace answers to a wider bound than a literal does" {
    const source = "pub enum E {\n" ++
        "    Unknown { cmsg_level: i32, cmsg_type: i32 },\n" ++
        "}\n" ++
        "\n" ++
        "fn f() {\n" ++
        "    let held = Held { cmsg_level: 1, cmsg_type: 2 };\n" ++
        "}\n";

    const wanted = "pub enum E {\n" ++
        "    Unknown { cmsg_level: i32, cmsg_type: i32 },\n" ++
        "}\n" ++
        "\n" ++
        "fn f() {\n" ++
        "    let held = Held {\n" ++
        "        cmsg_level: 1,\n" ++
        "        cmsg_type: 2,\n" ++
        "    };\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a variant holding a field attribute spreads every variant unless a tuple holds it" {
    const source = "enum A {\n" ++
        "    /// Pound.\n" ++
        "    Pound { acorns: u32 },\n" ++
        "\n" ++
        "    Sparkle {\n" ++
        "        #[arg(short)]\n" ++
        "        color: String,\n" ++
        "    },\n" ++
        "}\n" ++
        "\n" ++
        "enum B {\n" ++
        "    Pound { acorns: u32 },\n" ++
        "    Sparkle { #[arg(short)] color: String },\n" ++
        "}\n" ++
        "\n" ++
        "enum E {\n" ++
        "    Pound { acorns: u32 },\n" ++
        "    Sparkle(#[arg(short)] String),\n" ++
        "}\n";

    const wanted = "enum A {\n" ++
        "    /// Pound.\n" ++
        "    Pound { acorns: u32 },\n" ++
        "\n" ++
        "    Sparkle {\n" ++
        "        #[arg(short)]\n" ++
        "        color: String,\n" ++
        "    },\n" ++
        "}\n" ++
        "\n" ++
        "enum B {\n" ++
        "    Pound {\n" ++
        "        acorns: u32,\n" ++
        "    },\n" ++
        "    Sparkle {\n" ++
        "        #[arg(short)]\n" ++
        "        color: String,\n" ++
        "    },\n" ++
        "}\n" ++
        "\n" ++
        "enum E {\n" ++
        "    Pound { acorns: u32 },\n" ++
        "    Sparkle(#[arg(short)] String),\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a variant holding a line comment or a long tuple spreads every variant" {
    const source = "enum C {\n" ++
        "    Pound { acorns: u32 },\n" ++
        "    Sparkle {\n" ++
        "        // remark\n" ++
        "        color: String,\n" ++
        "    },\n" ++
        "}\n" ++
        "\n" ++
        "enum D {\n" ++
        "    Pound { acorns: u32 },\n" ++
        "    Long(SomeVeryLongTypeNameNumberOne, SomeVeryLongTypeNameNumberTwo, Three),\n" ++
        "}\n";

    const wanted = "enum C {\n" ++
        "    Pound {\n" ++
        "        acorns: u32,\n" ++
        "    },\n" ++
        "    Sparkle {\n" ++
        "        // remark\n" ++
        "        color: String,\n" ++
        "    },\n" ++
        "}\n" ++
        "\n" ++
        "enum D {\n" ++
        "    Pound {\n" ++
        "        acorns: u32,\n" ++
        "    },\n" ++
        "    Long(\n" ++
        "        SomeVeryLongTypeNameNumberOne,\n" ++
        "        SomeVeryLongTypeNameNumberTwo,\n" ++
        "        Three,\n" ++
        "    ),\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "an outer attribute written inline takes its own line where the reference gives it one" {
    const source = "#[derive(Debug)] struct S { #[a] x: u32, #[b(c)] y: u32 }\n" ++
        "\n" ++
        "struct T(#[a] u32, #[b] u32);\n" ++
        "\n" ++
        "impl X { #[inline] fn f(#[a] x: u32) {} }\n" ++
        "\n" ++
        "fn g() {\n" ++
        "    #[allow(x)] let a = 1;\n" ++
        "    match x { #[cfg(y)] A => 1, B => 2 }\n" ++
        "    let s = S { #[cfg(x)] a: 1, b: 2 };\n" ++
        "}\n";

    const wanted = "#[derive(Debug)]\n" ++
        "struct S {\n" ++
        "    #[a]\n" ++
        "    x: u32,\n" ++
        "    #[b(c)]\n" ++
        "    y: u32,\n" ++
        "}\n" ++
        "\n" ++
        "struct T(#[a] u32, #[b] u32);\n" ++
        "\n" ++
        "impl X {\n" ++
        "    #[inline]\n" ++
        "    fn f(#[a] x: u32) {}\n" ++
        "}\n" ++
        "\n" ++
        "fn g() {\n" ++
        "    #[allow(x)]\n" ++
        "    let a = 1;\n" ++
        "    match x {\n" ++
        "        #[cfg(y)]\n" ++
        "        A => 1,\n" ++
        "        B => 2,\n" ++
        "    }\n" ++
        "    let s = S {\n" ++
        "        #[cfg(x)]\n" ++
        "        a: 1,\n" ++
        "        b: 2,\n" ++
        "    };\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "an arm the source ended with a comma on its own line keeps the comma on its body line" {
    const source = "fn f() -> usize {\n" ++
        "    match state {\n" ++
        "        A => {\n" ++
        "            b(c)\n" ++
        "        },\n" ++
        "        B => { d(e) },\n" ++
        "        D => {\n" ++
        "            i(j)\n" ++
        "        } ,\n" ++
        "        F => k(l)\n" ++
        "        ,\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "fn f() -> usize {\n" ++
        "    match state {\n" ++
        "        A => b(c),\n" ++
        "        B => d(e),\n" ++
        "        D => i(j),\n" ++
        "        F => k(l),\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a statement holding a string line past the width is written from the source" {
    const source = "fn parse_positional() -> usize {\n" ++
        "    let  x  =  foo( \"This branch won't be hit,\n" ++
        "            because ParseState::Opt should not be seen as a positional argum" ++
        "ent and passed to this function.\" );\n" ++
        "    let  y  =  foo( \"aaaaaaaa\\\n" ++
        "         bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ++
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\" );\n" ++
        "    match  state  {\n" ++
        "        ParseState::ValueDone  =>  {\n" ++
        "            update_state_with_new_positional(pos_index)\n" ++
        "        },\n" ++
        "        ParseState::Opt(..) => unreachable!(\n" ++
        "            \"This branch won't be hit,\n" ++
        "            because ParseState::Opt should not be seen as a positional argum" ++
        "ent and passed to this function.\"\n" ++
        "        ),\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "fn parse_positional() -> usize {\n" ++
        "    let  x  =  foo( \"This branch won't be hit,\n" ++
        "            because ParseState::Opt should not be seen as a positional argum" ++
        "ent and passed to this function.\" );\n" ++
        "    let y = foo(\"aaaaaaaa\\\n" ++
        "         bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ++
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\");\n" ++
        "    match  state  {\n" ++
        "        ParseState::ValueDone  =>  {\n" ++
        "            update_state_with_new_positional(pos_index)\n" ++
        "        },\n" ++
        "        ParseState::Opt(..) => unreachable!(\n" ++
        "            \"This branch won't be hit,\n" ++
        "            because ParseState::Opt should not be seen as a positional argum" ++
        "ent and passed to this function.\"\n" ++
        "        ),\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a control body the source wrote on one line takes the lines the reference gives it" {
    const source = "fn f() {\n" ++
        "    if a { b }\n" ++
        "    while a { b }\n" ++
        "    for x in y { z }\n" ++
        "    if a { b } else { c };\n" ++
        "    if a { b } else if c { d } else { e }\n" ++
        "    let x = if a { b } else { c };\n" ++
        "    let minlen = if cfg!(miri) { cap - 1 } else { 1 }; // remark\n" ++
        "}\n";

    const wanted = "fn f() {\n" ++
        "    if a {\n" ++
        "        b\n" ++
        "    }\n" ++
        "    while a {\n" ++
        "        b\n" ++
        "    }\n" ++
        "    for x in y {\n" ++
        "        z\n" ++
        "    }\n" ++
        "    if a {\n" ++
        "        b\n" ++
        "    } else {\n" ++
        "        c\n" ++
        "    };\n" ++
        "    if a {\n" ++
        "        b\n" ++
        "    } else if c {\n" ++
        "        d\n" ++
        "    } else {\n" ++
        "        e\n" ++
        "    }\n" ++
        "    let x = if a { b } else { c };\n" ++
        "    let minlen = if cfg!(miri) { cap - 1 } else { 1 }; // remark\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a match arm body the source wrote on one line takes a block" {
    const source = "fn f() {\n" ++
        "    match x {\n" ++
        "        A => if a { b } else { c },\n" ++
        "        B => { if a { b } else { c } }\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "fn f() {\n" ++
        "    match x {\n" ++
        "        A => {\n" ++
        "            if a {\n" ++
        "                b\n" ++
        "            } else {\n" ++
        "                c\n" ++
        "            }\n" ++
        "        }\n" ++
        "        B => {\n" ++
        "            if a {\n" ++
        "                b\n" ++
        "            } else {\n" ++
        "                c\n" ++
        "            }\n" ++
        "        }\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a control head holding a block or a let keeps the body on the lines the reference gives it" {
    const source = "fn f() {\n" ++
        "    if unsafe { value.assume_init() } == v { w }\n" ++
        "    while let Some(edge) = unsafe { edge.ascend() } { edge = edge.next() }\n" ++
        "    if let Done { output } = self.project() { output }\n" ++
        "    while let Ok(chunk) = iter.next_chunk::<{ size_of::<u64>() }>() { chunk " ++
        "}\n" ++
        "    match tool {\n" ++
        "        Some(name) if name.contains(\"cl\") => Family::Msvc { clang_cl: true" ++
        " },\n" ++
        "        _ => Family::Gnu,\n" ++
        "    }\n" ++
        "    if self.state.is_empty() { result } else { None }.ok_or(AddrParseError(k" ++
        "ind))\n" ++
        "}\n";

    const wanted = "fn f() {\n" ++
        "    if unsafe { value.assume_init() } == v {\n" ++
        "        w\n" ++
        "    }\n" ++
        "    while let Some(edge) = unsafe { edge.ascend() } {\n" ++
        "        edge = edge.next()\n" ++
        "    }\n" ++
        "    if let Done { output } = self.project() {\n" ++
        "        output\n" ++
        "    }\n" ++
        "    while let Ok(chunk) = iter.next_chunk::<{ size_of::<u64>() }>() {\n" ++
        "        chunk\n" ++
        "    }\n" ++
        "    match tool {\n" ++
        "        Some(name) if name.contains(\"cl\") => Family::Msvc { clang_cl: true" ++
        " },\n" ++
        "        _ => Family::Gnu,\n" ++
        "    }\n" ++
        "    if self.state.is_empty() { result } else { None }.ok_or(AddrParseError(k" ++
        "ind))\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a list holding a string that spans lines parts unless a short callee hugs it" {
    const source = "fn f() {\n" ++
        "    foo(a, \"x\n" ++
        "y\");\n" ++
        "    Some(\"x\n" ++
        "y\");\n" ++
        "    Ok(\"x\n" ++
        "y\");\n" ++
        "    let x = food(\"aaaaaaaa\\\n" ++
        "         bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ++
        "bbbbbbbbbbbbbbbbbbbbbb\");\n" ++
        "    let y = foo(\"aaaaaaaa\\\n" ++
        "         bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ++
        "bbbbbbbbbbbbbbbbbbbbbb\");\n" ++
        "    x.met(\"a\n" ++
        "b\");\n" ++
        "}\n";

    const wanted = "fn f() {\n" ++
        "    foo(\n" ++
        "        a, \"x\n" ++
        "y\",\n" ++
        "    );\n" ++
        "    Some(\n" ++
        "        \"x\n" ++
        "y\",\n" ++
        "    );\n" ++
        "    Ok(\"x\n" ++
        "y\");\n" ++
        "    let x = food(\n" ++
        "        \"aaaaaaaa\\\n" ++
        "         bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ++
        "bbbbbbbbbbbbbbbbbbbbbb\",\n" ++
        "    );\n" ++
        "    let y = foo(\"aaaaaaaa\\\n" ++
        "         bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" ++
        "bbbbbbbbbbbbbbbbbbbbbb\");\n" ++
        "    x.met(\n" ++
        "        \"a\n" ++
        "b\",\n" ++
        "    );\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a macro holding a string that spans lines parts and a method on one breaks after it" {
    const source = "fn f() {\n" ++
        "    assert_eq!(a, \"x\n" ++
        "y\");\n" ++
        "    assert_eq!(a, b, \"x\n" ++
        "y\");\n" ++
        "    let s = format!(\"{}\n" ++
        "{}\", a, b);\n" ++
        "    assert_data_eq!(help, str![[r#\"\n" ++
        "Usage: test\n" ++
        "\"#]].raw());\n" ++
        "    let z = \"a\n" ++
        "b\".to_string();\n" ++
        "}\n";

    const wanted = "fn f() {\n" ++
        "    assert_eq!(\n" ++
        "        a,\n" ++
        "        \"x\n" ++
        "y\"\n" ++
        "    );\n" ++
        "    assert_eq!(\n" ++
        "        a, b,\n" ++
        "        \"x\n" ++
        "y\"\n" ++
        "    );\n" ++
        "    let s = format!(\n" ++
        "        \"{}\n" ++
        "{}\",\n" ++
        "        a, b\n" ++
        "    );\n" ++
        "    assert_data_eq!(\n" ++
        "        help,\n" ++
        "        str![[r#\"\n" ++
        "Usage: test\n" ++
        "\"#]]\n" ++
        "        .raw()\n" ++
        "    );\n" ++
        "    let z = \"a\n" ++
        "b\"\n" ++
        "    .to_string();\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a macro the reference cannot read as arguments is written from the source at its own level" {
    const source = "fn single_short_arg_without_value() {\n" ++
        "    let cmd = Command::new(\"cmd\")\n" ++
        "        .ignore_errors(true)\n" ++
        "        .arg(arg!(\n" ++
        "            -c --config <FILE> \"Sets a custom config file\"\n" ++
        "        ))\n" ++
        "        .arg(arg!(--\"unset-flag\"));\n" ++
        "}\n" ++
        "\n" ++
        "fn g() {\n" ++
        "    let cmd = Command::new(\"cmd\")\n" ++
        "        .ignore_errors(true)\n" ++
        "        .arg(arg!(\n" ++
        "            -c --config <FILE> \"Sets a custom config file\"\n" ++
        "        ));\n" ++
        "}\n";

    const wanted = "fn single_short_arg_without_value() {\n" ++
        "    let cmd = Command::new(\"cmd\")\n" ++
        "        .ignore_errors(true)\n" ++
        "        .arg(arg!(\n" ++
        "            -c --config <FILE> \"Sets a custom config file\"\n" ++
        "        ))\n" ++
        "        .arg(arg!(--\"unset-flag\"));\n" ++
        "}\n" ++
        "\n" ++
        "fn g() {\n" ++
        "    let cmd = Command::new(\"cmd\").ignore_errors(true).arg(arg!(\n" ++
        "        -c --config <FILE> \"Sets a custom config file\"\n" ++
        "    ));\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a macro the reference cannot read keeps its lines inside a chain and a readable one parts" {
    const source = "fn issue_753() {\n" ++
        "    let m = Command::new(\"test\")\n" ++
        "        .arg(\n" ++
        "            arg!(\n" ++
        "                -i --iface <INTERFACE> \"Ethernet interface for fetching NTP" ++
        " packets\"\n" ++
        "            )\n" ++
        "            .required(false)\n" ++
        "            .required_unless_present(\"list\"),\n" ++
        "        )\n" ++
        "        .arg(foo);\n" ++
        "}\n" ++
        "\n" ++
        "fn f() {\n" ++
        "    assert!(id > 0 && id < -1i32 as u32, \"spawning with pidfd still returns" ++
        " a sane pid\");\n" ++
        "    assert!(id > 0 && id < 1, \"spawning with pidfd still returns a sane pid" ++
        ", and some more text\");\n" ++
        "}\n";

    const wanted = "fn issue_753() {\n" ++
        "    let m = Command::new(\"test\")\n" ++
        "        .arg(\n" ++
        "            arg!(\n" ++
        "                -i --iface <INTERFACE> \"Ethernet interface for fetching NTP" ++
        " packets\"\n" ++
        "            )\n" ++
        "            .required(false)\n" ++
        "            .required_unless_present(\"list\"),\n" ++
        "        )\n" ++
        "        .arg(foo);\n" ++
        "}\n" ++
        "\n" ++
        "fn f() {\n" ++
        "    assert!(\n" ++
        "        id > 0 && id < -1i32 as u32,\n" ++
        "        \"spawning with pidfd still returns a sane pid\"\n" ++
        "    );\n" ++
        "    assert!(\n" ++
        "        id > 0 && id < 1,\n" ++
        "        \"spawning with pidfd still returns a sane pid, and some more text\"" ++
        "\n" ++
        "    );\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a parameter list the source parted joins where the signature fits" {
    const source = "trait T {\n" ++
        "    fn held<F>(\n" ++
        "        &self,\n" ++
        "        alpha: &[u8],\n" ++
        "        beta: usize,\n" ++
        "    ) -> Result<(), Self::Error>\n" ++
        "    where\n" ++
        "        F: FnMut(u8) -> bool,\n" ++
        "    {\n" ++
        "        g();\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "trait T {\n" ++
        "    fn held<F>(&self, alpha: &[u8], beta: usize) -> Result<(), Self::Error>\n" ++
        "    where\n" ++
        "        F: FnMut(u8) -> bool,\n" ++
        "    {\n" ++
        "        g();\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a list holding a block comment is still a list the layout parts" {
    const source = "fn f() {\n" ++
        "    panic_nounwind_fmt(fmt::Arguments::from_str(expr), " ++
        "/* force_no_backtrace */ false);\n" ++
        "}\n";

    const wanted = "fn f() {\n" ++
        "    panic_nounwind_fmt(\n" ++
        "        fmt::Arguments::from_str(expr),\n" ++
        "        /* force_no_backtrace */ false,\n" ++
        "    );\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a definition whose generics stand over lines parts its parameters too" {
    const source = "pub unsafe fn held<\n" ++
        "    T: CopyAndCloneAndSendAndSyncAndDebug,\n" ++
        "    const ORDERING: AtomicOrderingKindHeldWide,\n" ++
        ">(dst: *mut T, old: T, src: T) -> (T, bool);\n";

    const wanted = "pub unsafe fn held<\n" ++
        "    T: CopyAndCloneAndSendAndSyncAndDebug,\n" ++
        "    const ORDERING: AtomicOrderingKindHeldWide,\n" ++
        ">(\n" ++
        "    dst: *mut T,\n" ++
        "    old: T,\n" ++
        "    src: T,\n" ++
        ") -> (T, bool);\n";

    try expect_formatted(source, wanted);
}

test "a block value the source parted comes back on one line" {
    const source = "fn f() {\n" ++
        "    let held = unsafe {\n" ++
        "        gethostname(buf, maxlen)\n" ++
        "    };\n" ++
        "}\n";

    const wanted = "fn f() {\n" ++
        "    let held = unsafe { gethostname(buf, maxlen) };\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a block value carrying an attribute keeps its braces" {
    const source = "fn f() {\n" ++
        "    #[cfg(unix)]\n" ++
        "    unsafe {\n" ++
        "        gethostname(buf, maxlen)\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a struct field holding a lifetime still carries its own comment column" {
    const source = "pub struct C<'a> {\n" ++
        "    pub ip: *const u8, // one\n" ++
        "    pub start: &'a dyn Fn(u8), // two\n" ++
        "}\n";

    const wanted = "pub struct C<'a> {\n" ++
        "    pub ip: *const u8,         // one\n" ++
        "    pub start: &'a dyn Fn(u8), // two\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a match arm ending on its own body brace takes the comment column too" {
    const source = "fn f() {\n" ++
        "    match a {\n" ++
        "        Ok(_) => {} // one\n" ++
        "        Err(n) if n == addr => {} // two\n" ++
        "        _ => panic!(\"held\"),\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "fn f() {\n" ++
        "    match a {\n" ++
        "        Ok(_) => {}               // one\n" ++
        "        Err(n) if n == addr => {} // two\n" ++
        "        _ => panic!(\"held\"),\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a tuple of one element keeps the comma that makes it one" {
    const source = "trait X {\n" ++
        "    fn held<I: IntoIterator<Item = (T,)>>(&mut self, iter: I) {\n" ++
        "        g();\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a blank line between the comments of an otherwise empty body is kept" {
    const source = "fn f() {\n" ++
        "    // a\n" ++
        "\n" ++
        "    // b\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a closure leading several arguments still answers to the call width" {
    const source = "impl TypeSerializer for UnionSerializer {\n" ++
        "    fn to_python<'py>(&self, value: &Bound<'py, PyAny>) -> PyResult<Py<PyAny>> {\n" ++
        "        self.choices\n" ++
        "            .serialize(|comb_serializer, state| " ++
        "comb_serializer.to_python(value, state), state)?\n" ++
        "            .map_or_else(|| infer_to_python(value, state), Ok)\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "impl TypeSerializer for UnionSerializer {\n" ++
        "    fn to_python<'py>(&self, value: &Bound<'py, PyAny>) -> PyResult<Py<PyAny>> {\n" ++
        "        self.choices\n" ++
        "            .serialize(\n" ++
        "                |comb_serializer, state| comb_serializer.to_python(value, state),\n" ++
        "                state,\n" ++
        "            )?\n" ++
        "            .map_or_else(|| infer_to_python(value, state), Ok)\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a match arm returning a macro past the width takes the block the reference writes" {
    const source = "impl BuildValidator for ModelFieldsValidator {\n" ++
        "    fn build(schema: &Bound<'_, PyDict>) -> PyResult<Arc<CombinedValidator>> {\n" ++
        "        let extras_keys_validator = match (schema.get_item(intern!(py, " ++
        "\"extras_keys_schema\"))?, &extra_behavior) {\n" ++
        "            (Some(v), ExtraBehavior::Allow) => Some(build_validator(&v, " ++
        "config, definitions)?),\n" ++
        "            (Some(_), _) => return py_schema_err!(\"extras_keys_schema can only " ++
        "be used if extra_behavior=allow\"),\n" ++
        "            (_, _) => None,\n" ++
        "        };\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "impl BuildValidator for ModelFieldsValidator {\n" ++
        "    fn build(schema: &Bound<'_, PyDict>) -> PyResult<Arc<CombinedValidator>> {\n" ++
        "        let extras_keys_validator = match (\n" ++
        "            schema.get_item(intern!(py, \"extras_keys_schema\"))?,\n" ++
        "            &extra_behavior,\n" ++
        "        ) {\n" ++
        "            (Some(v), ExtraBehavior::Allow) => Some(build_validator(&v, " ++
        "config, definitions)?),\n" ++
        "            (Some(_), _) => {\n" ++
        "                return py_schema_err!(\n" ++
        "                    \"extras_keys_schema can only be used if extra_behavior=allow\"\n" ++
        "                );\n" ++
        "            }\n" ++
        "            (_, _) => None,\n" ++
        "        };\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a let condition that fits without its brace sends the brace to the next line" {
    const source = "fn f() {\n" ++
        "    let field_value = if let Some((field_info, field_json_value, other_value)) " ++
        "= field_resxxxxxxxxxx {\n" ++
        "        a\n" ++
        "    } else {\n" ++
        "        b\n" ++
        "    };\n" ++
        "}\n";

    const wanted = "fn f() {\n" ++
        "    let field_value = if let Some((field_info, field_json_value, other_value)) " ++
        "= field_resxxxxxxxxxx\n" ++
        "    {\n" ++
        "        a\n" ++
        "    } else {\n" ++
        "        b\n" ++
        "    };\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a generic default past the width stays on the line its parameter opens" {
    const source = "pub struct Intersection<\n" ++
        "    #[unstable(feature = \"allocator_api_and_some_more_text\", issue = \"32838\")] " ++
        "A: Allocator + Clone = Global,\n" ++
        "> {\n" ++
        "    inner: usize,\n" ++
        "}\n" ++
        "const ITER_PERFORMANCE_TIPPING_SIZE_DIFF: usize = 16;\n";

    try expect_formatted(source, source);
}

test "an empty body closes on its own brace" {
    const source = "struct S {\n" ++
        "}\n" ++
        "enum E {\n" ++
        "    A {\n" ++
        "    },\n" ++
        "    B {},\n" ++
        "}\n" ++
        "fn f() {\n" ++
        "}\n" ++
        "fn g() {\n" ++
        "    if x {\n" ++
        "    }\n" ++
        "    match y {\n" ++
        "    }\n" ++
        "    let z = S {\n" ++
        "    };\n" ++
        "    loop {\n" ++
        "    }\n" ++
        "}\n" ++
        "impl T for S {\n" ++
        "}\n" ++
        "trait U {\n" ++
        "}\n" ++
        "mod m {\n" ++
        "}\n";

    const wanted = "struct S {}\n" ++
        "enum E {\n" ++
        "    A {},\n" ++
        "    B {},\n" ++
        "}\n" ++
        "fn f() {}\n" ++
        "fn g() {\n" ++
        "    if x {}\n" ++
        "    match y {}\n" ++
        "    let z = S {};\n" ++
        "    loop {}\n" ++
        "}\n" ++
        "impl T for S {}\n" ++
        "trait U {}\n" ++
        "mod m {}\n";

    try expect_formatted(source, wanted);
}

test "an empty body stays open under an else or a where clause and closes in a macro" {
    const source = "fn h() {\n" ++
        "    if a {\n" ++
        "    } else {\n" ++
        "        b();\n" ++
        "    }\n" ++
        "    if a {} else if c {} else {}\n" ++
        "    for x in yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy.iter().map(|x| x + " ++
        "1).zip(zzzzzzzzzzzzzzzzzzzzzzzz.iter()).skip(1) {}\n" ++
        "}\n" ++
        "fn k<T>()\n" ++
        "where\n" ++
        "    T: Copy,\n" ++
        "{\n" ++
        "}\n" ++
        "macro_rules! m {\n" ++
        "}\n" ++
        "fn q() {\n" ++
        "    foo! {\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "fn h() {\n" ++
        "    if a {\n" ++
        "    } else {\n" ++
        "        b();\n" ++
        "    }\n" ++
        "    if a {\n" ++
        "    } else if c {\n" ++
        "    } else {\n" ++
        "    }\n" ++
        "    for x in yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy\n" ++
        "        .iter()\n" ++
        "        .map(|x| x + 1)\n" ++
        "        .zip(zzzzzzzzzzzzzzzzzzzzzzzz.iter())\n" ++
        "        .skip(1)\n" ++
        "    {}\n" ++
        "}\n" ++
        "fn k<T>()\n" ++
        "where\n" ++
        "    T: Copy,\n" ++
        "{\n" ++
        "}\n" ++
        "macro_rules! m {}\n" ++
        "fn q() {\n" ++
        "    foo! {}\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "an arm block holding one expression the source chained over lines takes the arm line" {
    const source = "impl P {\n" ++
        "    fn parse_flag(&self) -> Result<ast::Flag> {\n" ++
        "        match self.char() {\n" ++
        "            'x' => Ok(ast::Flag::IgnoreWhitespace),\n" ++
        "            _ => {\n" ++
        "                Err(self\n" ++
        "                    .error(self.span_char(), " ++
        "ast::ErrorKind::FlagUnrecognized))\n" ++
        "            }\n" ++
        "        }\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "impl P {\n" ++
        "    fn parse_flag(&self) -> Result<ast::Flag> {\n" ++
        "        match self.char() {\n" ++
        "            'x' => Ok(ast::Flag::IgnoreWhitespace),\n" ++
        "            _ => Err(self.error(self.span_char(), " ++
        "ast::ErrorKind::FlagUnrecognized)),\n" ++
        "        }\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "an arm block holding a match takes the arm line when the match head fits" {
    const source = "impl P {\n" ++
        "    fn induct_class(&self, ast: &ClassInduct<'a>) -> Option<ClassFrame<'a>> " ++
        "{\n" ++
        "        match *ast {\n" ++
        "            ClassInduct::Item(&ast::ClassSetItem::Bracketed(ref x)) => {\n" ++
        "                match x.kind {\n" ++
        "                    ast::ClassSet::Item(ref item) => {\n" ++
        "                        Some(ClassFrame::Union { head: item, tail: &[] })\n" ++
        "                    }\n" ++
        "                    ast::ClassSet::BinaryOp(ref op) => {\n" ++
        "                        Some(ClassFrame::Binary { op })\n" ++
        "                    }\n" ++
        "                }\n" ++
        "            }\n" ++
        "            _ => None,\n" ++
        "        }\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "impl P {\n" ++
        "    fn induct_class(&self, ast: &ClassInduct<'a>) -> Option<ClassFrame<'a>> " ++
        "{\n" ++
        "        match *ast {\n" ++
        "            ClassInduct::Item(&ast::ClassSetItem::Bracketed(ref x)) => " ++
        "match x.kind {\n" ++
        "                ast::ClassSet::Item(ref item) => Some(ClassFrame::Union {\n" ++
        "                    head: item,\n" ++
        "                    tail: &[],\n" ++
        "                }),\n" ++
        "                ast::ClassSet::BinaryOp(ref op) => Some(ClassFrame::Binary " ++
        "{ op }),\n" ++
        "            },\n" ++
        "            _ => None,\n" ++
        "        }\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a generic list the source spread joins when its arguments fit the line" {
    const source = "mod tests {\n" ++
        "    fn oibits() {\n" ++
        "        assert_oitbits::<\n" ++
        "            Pool<\n" ++
        "                Vec<u32>,\n" ++
        "                Box<\n" ++
        "                    dyn Fn() -> Vec<u32>\n" ++
        "                        + Send\n" ++
        "                        + Sync\n" ++
        "                        + UnwindSafe\n" ++
        "                        + RefUnwindSafe,\n" ++
        "                >,\n" ++
        "            >,\n" ++
        "        >();\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "mod tests {\n" ++
        "    fn oibits() {\n" ++
        "        assert_oitbits::<\n" ++
        "            Pool<Vec<u32>, Box<dyn Fn() -> Vec<u32> + Send + Sync + " ++
        "UnwindSafe + RefUnwindSafe>>,\n" ++
        "        >();\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a macro keeps its trailing comma in the width of the line it would join" {
    const source = "fn invalid_byte_classes() {\n" ++
        "    let data = include_bytes!(\n" ++
        "        \"testdata/deserialize_dense_crash-9486fb7c8a93b12c12a62166b43d31640" ++
        "c0208a9\",\n" ++
        "    );\n" ++
        "    let _ = fuzz_run(data);\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "the generics of a function leave room for the parameters and brace after them" {
    const source = "fn into_iter_helper<\n" ++
        "    T: Copy,\n" ++
        "    F: FnOnce(&mut VecDeque<T>),\n" ++
        "    G: FnOnce(&mut vec_deque::IntoIter<T>),\n" ++
        ">(\n" ++
        "    v: &mut VecDeque<T>,\n" ++
        "    size: usize,\n" ++
        ") {\n" ++
        "    v.clear();\n" ++
        "}\n" ++
        "\n" ++
        "trait Helped {\n" ++
        "    fn into_iter_he<\n" ++
        "        T: Copy,\n" ++
        "        F: FnOnce(&mut VecDeque<T>),\n" ++
        "        G: FnOnce(&mut vec_deque::IntoIter<T>),\n" ++
        "    >(\n" ++
        "        v: &mut VecDeque<T>,\n" ++
        "    );\n" ++
        "}\n";

    const wanted = "fn into_iter_helper<\n" ++
        "    T: Copy,\n" ++
        "    F: FnOnce(&mut VecDeque<T>),\n" ++
        "    G: FnOnce(&mut vec_deque::IntoIter<T>),\n" ++
        ">(\n" ++
        "    v: &mut VecDeque<T>,\n" ++
        "    size: usize,\n" ++
        ") {\n" ++
        "    v.clear();\n" ++
        "}\n" ++
        "\n" ++
        "trait Helped {\n" ++
        "    fn into_iter_he<T: Copy, F: FnOnce(&mut VecDeque<T>), G: FnOnce(&mut " ++
        "vec_deque::IntoIter<T>)>(\n" ++
        "        v: &mut VecDeque<T>,\n" ++
        "    );\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "the generics of a function leave room for the where clause and a parted macro stays parted" {
    const source = "fn into_iter_helpe<\n" ++
        "    T: Copy,\n" ++
        "    F: FnOnce(&mut VecDeque<T>),\n" ++
        "    G: FnOnce(&mut vec_deque::IntoIter<T>),\n" ++
        ">(\n" ++
        "    v: &mut VecDeque<T>,\n" ++
        "    size: usize,\n" ++
        ") where\n" ++
        "    T: Clone,\n" ++
        "{\n" ++
        "    v.clear();\n" ++
        "}\n" ++
        "\n" ++
        "fn f() {\n" ++
        "    assert_eq!(\n" ++
        "        NonZero::<u128>::new(1 << 127).unwrap().trailing_zeros(),\n" ++
        "        127\n" ++
        "    );\n" ++
        "    assert!(\n" ++
        "        index < MMMMMMMMMMMM,\n" ++
        "        \"source element index exceeds input vector length because of " ++
        "reasons\"\n" ++
        "    );\n" ++
        "}\n";

    const wanted = "fn into_iter_helpe<T: Copy, F: FnOnce(&mut VecDeque<T>), G: FnOnce(&mut " ++
        "vec_deque::IntoIter<T>)>(\n" ++
        "    v: &mut VecDeque<T>,\n" ++
        "    size: usize,\n" ++
        ") where\n" ++
        "    T: Clone,\n" ++
        "{\n" ++
        "    v.clear();\n" ++
        "}\n" ++
        "\n" ++
        "fn f() {\n" ++
        "    assert_eq!(\n" ++
        "        NonZero::<u128>::new(1 << 127).unwrap().trailing_zeros(),\n" ++
        "        127\n" ++
        "    );\n" ++
        "    assert!(\n" ++
        "        index < MMMMMMMMMMMM,\n" ++
        "        \"source element index exceeds input vector length because of " ++
        "reasons\"\n" ++
        "    );\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a struct literal after a unary not is no macro and takes its trailing comma when spread" {
    const source = "fn f() {\n" ++
        "    if !(ClassRange { start: 'a', end: 'z' }).is_intersection_empty(self) " ++
        "{\n" ++
        "        g();\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "fn f() {\n" ++
        "    if !(ClassRange {\n" ++
        "        start: 'a',\n" ++
        "        end: 'z',\n" ++
        "    })\n" ++
        "    .is_intersection_empty(self)\n" ++
        "    {\n" ++
        "        g();\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "pattern alternatives take a line each unless they fit the arm line with its arrow and brace" {
    const source = "impl BuildError {\n" ++
        "    pub fn is_size_limit_exceeded(&self) -> bool {\n" ++
        "        match self.kind {\n" ++
        "            NFA(_) | Unsupported(_) => false,\n" ++
        "            TooManyStates\n" ++
        "            | TooManyStartStates\n" ++
        "            | TooManyMatchPatternIDs\n" ++
        "            | DFAExceededSizeLimit { .. }\n" ++
        "            | DeterminizeExceededSizeLimit { .. } => true,\n" ++
        "        }\n" ++
        "    }\n" ++
        "\n" ++
        "    fn attribute(&self) {\n" ++
        "        match attr.name() {\n" ++
        "            constants::DW_AT_byte_size\n" ++
        "            | constants::DW_AT_bit_offset\n" ++
        "            | constants::DW_AT_bit_size => {\n" ++
        "                constant!(udata_value, Udata);\n" ++
        "                exprloc!();\n" ++
        "            }\n" ++
        "            constants::DW_AT_byte_size\n" ++
        "            | constants::DW_AT_bit_offset\n" ++
        "            | constants::DW_AT_bitsize => {\n" ++
        "                exprloc!();\n" ++
        "            }\n" ++
        "        }\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "impl BuildError {\n" ++
        "    pub fn is_size_limit_exceeded(&self) -> bool {\n" ++
        "        match self.kind {\n" ++
        "            NFA(_) | Unsupported(_) => false,\n" ++
        "            TooManyStates\n" ++
        "            | TooManyStartStates\n" ++
        "            | TooManyMatchPatternIDs\n" ++
        "            | DFAExceededSizeLimit { .. }\n" ++
        "            | DeterminizeExceededSizeLimit { .. } => true,\n" ++
        "        }\n" ++
        "    }\n" ++
        "\n" ++
        "    fn attribute(&self) {\n" ++
        "        match attr.name() {\n" ++
        "            constants::DW_AT_byte_size\n" ++
        "            | constants::DW_AT_bit_offset\n" ++
        "            | constants::DW_AT_bit_size => {\n" ++
        "                constant!(udata_value, Udata);\n" ++
        "                exprloc!();\n" ++
        "            }\n" ++
        "            constants::DW_AT_byte_size | constants::DW_AT_bit_offset | " ++
        "constants::DW_AT_bitsize => {\n" ++
        "                exprloc!();\n" ++
        "            }\n" ++
        "        }\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a joined list keeps the width of the comma that ends its line" {
    const source = "impl File {\n" ++
        "    pub fn file_attr(&self) -> io::Result<FileAttr> {\n" ++
        "        unsafe {\n" ++
        "            Ok(FileAttr {\n" ++
        "                file_index: Some(\n" ++
        "                    (info.nFileIndexLow as u64) | ((info.nFileIndexHigh as " ++
        "u64) << 32),\n" ++
        "                ),\n" ++
        "            })\n" ++
        "        }\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a sole string list is measured on the line it stands on" {
    const source = "mod t {\n" ++
        "    fn f() {\n" ++
        "        let script = get_fish_registration(\"/path/completer\");\n" ++
        "        assert_data_eq!(\n" ++
        "            script.trim(),\n" ++
        "            snapbox::str![r#\"complete [..] \"([..] /path/completer " ++
        "[..])\"\"#]\n" ++
        "        );\n" ++
        "\n" ++
        "        let script = get_fish_registration(\"/path with a " ++
        "space/completer\");\n" ++
        "        assert_data_eq!(\n" ++
        "            script.trim(),\n" ++
        "            snapbox::str![r#\"complete [..] \"([..] '/path with a " ++
        "space/completer' [..])\"\"#]\n" ++
        "        );\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a sole call argument the source spread joins when the whole call fits the line" {
    const source = "impl Parser {\n" ++
        "    fn parse_group(&self) -> Result<ast::Group> {\n" ++
        "        if self.is_eof() {\n" ++
        "            return Err(self.error(\n" ++
        "                self.span_char(),\n" ++
        "                ast::ErrorKind::GroupNameInvalid,\n" ++
        "            ));\n" ++
        "        }\n" ++
        "        Ok(())\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "impl Parser {\n" ++
        "    fn parse_group(&self) -> Result<ast::Group> {\n" ++
        "        if self.is_eof() {\n" ++
        "            return Err(self.error(self.span_char(), " ++
        "ast::ErrorKind::GroupNameInvalid));\n" ++
        "        }\n" ++
        "        Ok(())\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a break value at the full width parts the way a return value does" {
    const source = "fn f() {\n" ++
        "    {\n" ++
        "        break Err(ast::ErrorKind::ffffffffffffffffffffffffffffffffffffffffff" ++
        "ffffffffffffffffffffff);\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "fn f() {\n" ++
        "    {\n" ++
        "        break Err(\n" ++
        "            ast::ErrorKind::ffffffffffffffffffffffffffffffffffffffffffffffff" ++
        "ffffffffffffffff,\n" ++
        "        );\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a bound plus inside a turbofish stays on the chain link line" {
    const source = "fn f() {\n" ++
        "    let (mut client, conn) = conn::http2::Builder::new(TokioExecutor)\n" ++
        "        .handshake::<_, BoxBody<Bytes, Box<dyn Error + Send + Sync>>>(io)\n" ++
        "        .await\n" ++
        "        .expect(\"http handshake\");\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "chain links under a turbofish root that closes on its own line keep the root level" {
    const source = "async fn run(io: impl Read + Write + Unpin + 'static) {\n" ++
        "    let (_sender, conn) = crate::client::conn::http2::handshake::<\n" ++
        "        _,\n" ++
        "        _,\n" ++
        "        http_body_util::Empty<bytes::Bytes>,\n" ++
        "    >(LocalTokioExecutor, io)\n" ++
        "    .await\n" ++
        "    .unwrap();\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a macro argument opening on a binary operator is kept as written" {
    const source = "fn f() {\n" ++
        "    trace!(error = %e, \"force_io_read; io error\");\n" ++
        "    debug!( %e ,  \"connection error\");\n" ++
        "    debug!(error =  %e, \"x\");\n" ++
        "    debug!(error = ?e, \"connection error\");\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a macro rule calling a macro with a colon argument is kept as written" {
    const source = "macro_rules! m {\n" ++
        "    ($name:tt: $val:tt) => {{\n" ++
        "        __internal_req_res_prop!($name: $val)\n" ++
        "    }};\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a match brace joins a scrutinee whose last line only closes" {
    const source = "fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> " ++
        "Poll<Self::Output> {\n" ++
        "    match ready!(Pin::new(\n" ++
        "        &mut self\n" ++
        "            .inner\n" ++
        "            .as_mut()\n" ++
        "            .expect(\"upgradeable client connection polled after " ++
        "upgrade\")\n" ++
        "            .inner,\n" ++
        "    )\n" ++
        "    .poll(cx))\n" ++
        "    {\n" ++
        "        Ok(Dispatched::Shutdown) => Poll::Ready(Ok(())),\n" ++
        "        Err(e) => Poll::Ready(Err(e)),\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "fn poll(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> " ++
        "Poll<Self::Output> {\n" ++
        "    match ready!(\n" ++
        "        Pin::new(\n" ++
        "            &mut self\n" ++
        "                .inner\n" ++
        "                .as_mut()\n" ++
        "                .expect(\"upgradeable client connection polled after " ++
        "upgrade\")\n" ++
        "                .inner,\n" ++
        "        )\n" ++
        "        .poll(cx)\n" ++
        "    ) {\n" ++
        "        Ok(Dispatched::Shutdown) => Poll::Ready(Ok(())),\n" ++
        "        Err(e) => Poll::Ready(Err(e)),\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "where clause bounds rustfmt breaks are indented past their predicate" {
    const source = "impl<D, Bs, I, T> Dispatcher<D, Bs, I, T>\n" ++
        "where\n" ++
        "    D: Dispatch<\n" ++
        "            PollItem = MessageHead<T::Outgoing>,\n" ++
        "            PollBody = Bs,\n" ++
        "            RecvItem = MessageHead<T::Incoming>,\n" ++
        "        > + Unpin,\n" ++
        "    D::PollError: Into<Box<dyn StdError + Send + Sync>>,\n" ++
        "    F: Dispatch<\n" ++
        "            PollItem = MessageHead<T::Outgoing>,\n" ++
        "            PollBody = Bs,\n" ++
        "            RecvItem = MessageHead<T::Incoming>,\n" ++
        "        > + Unpin\n" ++
        "        + Send\n" ++
        "        + 'static,\n" ++
        "    G: Unpin\n" ++
        "        + Dispatch<\n" ++
        "            PollItem = MessageHead<T::Outgoing>,\n" ++
        "            PollBody = Bs,\n" ++
        "            RecvItem = MessageHead<T::Incoming>,\n" ++
        "        >,\n" ++
        "    J: Dispatch<\n" ++
        "        MessageHeadxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" ++
        "xxxxxxxxxxxxxxxxxxxx,\n" ++
        "    >,\n" ++
        "{\n" ++
        "    fn f() {}\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "use items under attributes spanning lines are ordered by path" {
    const source = "#[cfg(all(feature = \"http1\", any(feature = \"client\", feature = " ++
        "\"server\")))]\n" ++
        "use super::chan;\n" ++
        "#[cfg(all(\n" ++
        "    any(feature = \"http1\", feature = \"http2\"),\n" ++
        "    any(feature = \"client\", feature = \"server\")\n" ++
        "))]\n" ++
        "use super::DecodedLength;\n" ++
        "#[cfg(all(feature = \"http2\", any(feature = \"client\", feature = " ++
        "\"server\")))]\n" ++
        "use crate::proto::h2::ping;\n";

    const wanted = "#[cfg(all(\n" ++
        "    any(feature = \"http1\", feature = \"http2\"),\n" ++
        "    any(feature = \"client\", feature = \"server\")\n" ++
        "))]\n" ++
        "use super::DecodedLength;\n" ++
        "#[cfg(all(feature = \"http1\", any(feature = \"client\", feature = " ++
        "\"server\")))]\n" ++
        "use super::chan;\n" ++
        "#[cfg(all(feature = \"http2\", any(feature = \"client\", feature = " ++
        "\"server\")))]\n" ++
        "use crate::proto::h2::ping;\n";

    try expect_formatted(source, wanted);
}

test "a use list holding a nested group is sorted before it is laid out" {
    const source = "use http::{\n" ++
        "    header::{\n" ++
        "        AUTHORIZATION, CACHE_CONTROL, CONTENT_ENCODING, CONTENT_LENGTH, " ++
        "CONTENT_RANGE,\n" ++
        "        CONTENT_TYPE, HOST, MAX_FORWARDS, SET_COOKIE, TE, TRAILER, " ++
        "TRANSFER_ENCODING,\n" ++
        "    },\n" ++
        "    HeaderMap, HeaderName,\n" ++
        "};\n" ++
        "use {\n" ++
        "    core::{\n" ++
        "        alloc::Layout,\n" ++
        "        fmt,\n" ++
        "        future::Future,\n" ++
        "        pin::Pin,\n" ++
        "        ptr,\n" ++
        "        sync::atomic::{AtomicU32, Ordering::Relaxed},\n" ++
        "        task::{Context, Poll},\n" ++
        "    },\n" ++
        "    crate::rt::Cleanup,\n" ++
        "};\n";

    const wanted = "use http::{\n" ++
        "    HeaderMap, HeaderName,\n" ++
        "    header::{\n" ++
        "        AUTHORIZATION, CACHE_CONTROL, CONTENT_ENCODING, CONTENT_LENGTH, " ++
        "CONTENT_RANGE,\n" ++
        "        CONTENT_TYPE, HOST, MAX_FORWARDS, SET_COOKIE, TE, TRAILER, " ++
        "TRANSFER_ENCODING,\n" ++
        "    },\n" ++
        "};\n" ++
        "use {\n" ++
        "    crate::rt::Cleanup,\n" ++
        "    core::{\n" ++
        "        alloc::Layout,\n" ++
        "        fmt,\n" ++
        "        future::Future,\n" ++
        "        pin::Pin,\n" ++
        "        ptr,\n" ++
        "        sync::atomic::{AtomicU32, Ordering::Relaxed},\n" ++
        "        task::{Context, Poll},\n" ++
        "    },\n" ++
        "};\n";

    try expect_formatted(source, wanted);
}

test "a use statement inside a macro invocation is left in its order" {
    const source = "nonpoison_and_poison_unwrap_test!(\n" ++
        "    name: test_mapped_mutex_guard,\n" ++
        "    test_body: {\n" ++
        "        use locks::{Mutex, MutexGuard, MappedMutexGuard};\n" ++
        "\n" ++
        "        let mutex = Mutex::new(vec![]);\n" ++
        "    }\n" ++
        ");\n";

    try expect_formatted(source, source);
}

test "a wide character in a string counts two columns toward the width" {
    const source = "fn f() {\n" ++
        "    if buffered > 0 {\n" ++
        "        eprintln!(\"\\n\u{274C}BUG: shutdown() called with {} bytes buffered\", " ++
        "buffered);\n" ++
        "        stats.shutdown_called_with_buffered = true;\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "fn f() {\n" ++
        "    if buffered > 0 {\n" ++
        "        eprintln!(\n" ++
        "            \"\\n\u{274C}BUG: shutdown() called with {} bytes buffered\",\n" ++
        "            buffered\n" ++
        "        );\n" ++
        "        stats.shutdown_called_with_buffered = true;\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a closure body that loops or branches over lines takes a forced block" {
    const source = "fn f() {\n" ++
        "    let a = future::poll_fn(|cx| loop {\n" ++
        "        if let Poll::Ready(res) = fut.as_mut().poll(cx) {\n" ++
        "            return Poll::Ready(res);\n" ++
        "        }\n" ++
        "        return Poll::Pending;\n" ++
        "    })\n" ++
        "    .await;\n" ++
        "    let b = poll_fn(|cx| if x { 1 } else { 2 });\n" ++
        "    let c = |cx| loop {\n" ++
        "        foo();\n" ++
        "    };\n" ++
        "    let d = |cx| while x {\n" ++
        "        go(y);\n" ++
        "    };\n" ++
        "}\n";

    const wanted = "fn f() {\n" ++
        "    let a = future::poll_fn(|cx| {\n" ++
        "        loop {\n" ++
        "            if let Poll::Ready(res) = fut.as_mut().poll(cx) {\n" ++
        "                return Poll::Ready(res);\n" ++
        "            }\n" ++
        "            return Poll::Pending;\n" ++
        "        }\n" ++
        "    })\n" ++
        "    .await;\n" ++
        "    let b = poll_fn(|cx| if x { 1 } else { 2 });\n" ++
        "    let c = |cx| loop {\n" ++
        "        foo();\n" ++
        "    };\n" ++
        "    let d = |cx| {\n" ++
        "        while x {\n" ++
        "            go(y);\n" ++
        "        }\n" ++
        "    };\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "an or-pattern after a struct pattern keeps one alternative per line" {
    const source = "fn f(err: &Error) -> StatusCode {\n" ++
        "    match err {\n" ++
        "        Error::UnknownField { .. }\n" ++
        "        | Error::DecodeHeaderValue { .. }\n" ++
        "        | Error::NoMultipart\n" ++
        "        | Error::IncompleteStream => StatusCode::BAD_REQUEST,\n" ++
        "        _ => StatusCode::INTERNAL_SERVER_ERROR,\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "an empty parameter list whose return type overflows puts the arrow on its own line" {
    const source = "async fn multipart_form_rejects_newlines_in_field_metadata_" ++
        "and_more_words_here(\n" ++
        ") -> Result<(), Box<dyn Error>> {\n" ++
        "    Ok(())\n" ++
        "}\n";

    const wanted = "async fn multipart_form_rejects_newlines_in_field_metadata_" ++
        "and_more_words_here()\n" ++
        "-> Result<(), Box<dyn Error>> {\n" ++
        "    Ok(())\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a return type broken from parameters that fit joins the signature line" {
    const source = "fn f()\n" ++
        "-> u32 {\n" ++
        "    1\n" ++
        "}\n" ++
        "\n" ++
        "fn g(a: u32)\n" ++
        "-> u32 {\n" ++
        "    1\n" ++
        "}\n";

    const wanted = "fn f() -> u32 {\n" ++
        "    1\n" ++
        "}\n" ++
        "\n" ++
        "fn g(a: u32) -> u32 {\n" ++
        "    1\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a multi-line tuple chain root indents its links" {
    const source = "fn f() {\n" ++
        "    let res = (\n" ++
        "        StatusCode::SEE_OTHER,\n" ++
        "        [(\"location\", \"foo\")],\n" ++
        "        StatusCode::NO_CONTENT,\n" ++
        "    )\n" ++
        "        .into_response();\n" ++
        "    match self {\n" ++
        "        Err(err) => (\n" ++
        "            StatusCode::INTERNAL_SERVER_ERROR,\n" ++
        "            IntoResponseFailed,\n" ++
        "            err.to_string(),\n" ++
        "        )\n" ++
        "            .into_response(),\n" ++
        "    }\n" ++
        "    let response = handshake::<_, ()>(\n" ++
        "        &ctx.paths.tunnel_lockfile(),\n" ++
        "        protocol::singleton::METHOD_RESTART,\n" ++
        "    )\n" ++
        "    .await\n" ++
        "    .unwrap();\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a single-element tuple root counts its comma toward the chain width" {
    const source = "fn f() {\n" ++
        "    assert_eq!(\n" ++
        "        (StatusCode::INTERNAL_SERVER_ERROR,)\n" ++
        "            .into_response()\n" ++
        "            .status(),\n" ++
        "        StatusCode::INTERNAL_SERVER_ERROR\n" ++
        "    );\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a dot after a tuple index glues to it" {
    const source = "fn f() {\n" ++
        "    let a = extension.map(|foo| foo.0 .0).unwrap_or(\"none\".to_owned());\n" ++
        "    let c = foo.0 .1 .2;\n" ++
        "    let d = 1.0;\n" ++
        "}\n";

    const wanted = "fn f() {\n" ++
        "    let a = extension.map(|foo| foo.0.0).unwrap_or(\"none\".to_owned());\n" ++
        "    let c = foo.0.1.2;\n" ++
        "    let d = 1.0;\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a cooked string that fits on no line stays beside its assignment" {
    const source = "const TAKE_ONCE_ROUTE_PANIC_MSG: &str =\n" ++
        "    \"TakeOnceRoute called more than once; if this was not triggered by an " ++
        "intentional test, this should never happen. Please file an issue.\";\n" ++
        "\n" ++
        "fn f() {\n" ++
        "    let message =\n" ++
        "        \"TakeOnceRoute called more than once; if this was not triggered by " ++
        "an intentional test\";\n" ++
        "    let expected_response =\n" ++
        "        b\"HTTP/1.1 200 OK\\r\\nContent-Length: 10\\r\\nContent-Type: " ++
        "application/json\\r\\nWeird--Header: \\r\\n\";\n" ++
        "}\n";

    const wanted = "const TAKE_ONCE_ROUTE_PANIC_MSG: &str = \"TakeOnceRoute called more than " ++
        "once; if this was not triggered by an intentional test, this should never " ++
        "happen. Please file an issue.\";\n" ++
        "\n" ++
        "fn f() {\n" ++
        "    let message =\n" ++
        "        \"TakeOnceRoute called more than once; if this was not triggered by " ++
        "an intentional test\";\n" ++
        "    let expected_response =\n" ++
        "        b\"HTTP/1.1 200 OK\\r\\nContent-Length: 10\\r\\nContent-Type: " ++
        "application/json\\r\\nWeird--Header: \\r\\n\";\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a trailing comment on a closer line keeps the next link at its level" {
    const source = "fn f() {\n" ++
        "    let app = Router::new()\n" ++
        "        .route(\"/users\", post(users_create))\n" ++
        "        .layer(from_fn(log_app_errors)) // <- Inner layer\n" ++
        "        .layer(\n" ++
        "            TraceLayer::new_for_http()\n" ++
        "                .make_span_with(|req: &Request| " ++
        "tracing::debug_span!(\"request\"))\n" ++
        "                .on_failure(()),\n" ++
        "        ) // <- Outer layer\n" ++
        "        .with_state(state);\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a closure body holding a lone brace macro keeps its block" {
    const source = "fn f() {\n" ++
        "    let args = item_fn.sig.inputs.iter().map(|_| {\n" ++
        "        quote_spanned! {span=> panic!() }\n" ++
        "    });\n" ++
        "    let b = items.iter().map(|_| {\n" ++
        "        quote!(span)\n" ++
        "    });\n" ++
        "    let c = items.iter().map(|_| {\n" ++
        "        vec![1, 2]\n" ++
        "    });\n" ++
        "}\n";

    const wanted = "fn f() {\n" ++
        "    let args = item_fn.sig.inputs.iter().map(|_| {\n" ++
        "        quote_spanned! {span=> panic!() }\n" ++
        "    });\n" ++
        "    let b = items.iter().map(|_| quote!(span));\n" ++
        "    let c = items.iter().map(|_| vec![1, 2]);\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a chain root call owes the statement semicolon" {
    const source = "fn f() {\n" ++
        "    for arg in args {\n" ++
        "        let (span, ty) = match arg {\n" ++
        "            FnArg::Receiver(receiver) => {\n" ++
        "                if receiver.reference.is_some() {\n" ++
        "                    return syn::Error::new_spanned(\n" ++
        "                        receiver,\n" ++
        "                        \"Handlers must only take owned values\",\n" ++
        "                    )\n" ++
        "                    .into_compile_error();\n" ++
        "                }\n" ++
        "            }\n" ++
        "        };\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "an arm body casting or wrapping a broken literal stays beside its arrow" {
    const source = "fn infer_state_type_from_field_types(fields: &Fields) -> impl Iterator<Item " ++
        "= Type> + '_ {\n" ++
        "    match fields {\n" ++
        "        Fields::Named(fields_named) => Box::new(crate::infer_state_types(\n" ++
        "            fields_named.named.iter().map(|field| &field.ty),\n" ++
        "        )) as Box<dyn Iterator<Item = Type>>,\n" ++
        "        Fields::Unnamed(fields_unnamed) => " ++
        "Box::new(crate::infer_state_types(\n" ++
        "            fields_unnamed.unnamed.iter().map(|field| &field.ty),\n" ++
        "        )),\n" ++
        "        Fields::Unit => Box::new(iter::empty()),\n" ++
        "    }\n" ++
        "}\n" ++
        "\n" ++
        "fn from_request_parts() -> Result<Self, RawPathParamsRejection> {\n" ++
        "    match extensions.get::<UrlParams>() {\n" ++
        "        Some(UrlParams::Params { params, .. }) => " ++
        "Ok(Self(params.clone())),\n" ++
        "        Some(UrlParams::InvalidUtf8InPathParam { key }) => " ++
        "Err(InvalidUtf8InPathParam {\n" ++
        "            key: Arc::clone(key),\n" ++
        "        }\n" ++
        "        .into()),\n" ++
        "        None => Err(MissingPathParams.into()),\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "turbofish arguments inside hugged calls indent from their line" {
    const source = "fn f() {\n" ++
        "    {\n" ++
        "        Err(PathDeserializationError::unsupported_type(type_name::<\n" ++
        "            V::Value,\n" ++
        "        >()))\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a signature followed by a where clause spreads its parameters when too wide" {
    const source = "impl X {\n" ++
        "    fn deserialize_tuple_struct<V>(self, _name: &'static str, _len: usize, " ++
        "_visitor: V) -> Result<V::Value, Self::Error>\n" ++
        "    where\n" ++
        "        V: Visitor<'de>,\n" ++
        "    {\n" ++
        "        1\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "impl X {\n" ++
        "    fn deserialize_tuple_struct<V>(\n" ++
        "        self,\n" ++
        "        _name: &'static str,\n" ++
        "        _len: usize,\n" ++
        "        _visitor: V,\n" ++
        "    ) -> Result<V::Value, Self::Error>\n" ++
        "    where\n" ++
        "        V: Visitor<'de>,\n" ++
        "    {\n" ++
        "        1\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a closure body under a closure argument takes no call cascade budget" {
    const source = "fn f() {\n" ++
        "    {\n" ++
        "        let app = ServiceBuilder::new()\n" ++
        "            .layer_fn(|_| tower::service_fn(|_| " ++
        "std::future::ready(Ok(Response::new(CustomBody)))))\n" ++
        "            .service(Router::<()>::new().route(\"/hello\", get(|| async " ++
        "{})));\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a glued tuple index counts once toward a call width" {
    const source = "mod tests {\n" ++
        "    async fn f() {\n" ++
        "        let app = Router::new().route(\"/{key}\", get(|param: Path<Param>| " ++
        "async move { param.0 .0 }));\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "mod tests {\n" ++
        "    async fn f() {\n" ++
        "        let app = Router::new().route(\"/{key}\", get(|param: Path<Param>| " ++
        "async move { param.0.0 }));\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a multi-line last argument that cannot overflow spreads a list of several" {
    const source = "fn main() {\n" ++
        "    move_value(&mut document, &[\"draw_bold_text_with_bright_colors\"], " ++
        "&[\n" ++
        "        \"colors\",\n" ++
        "        \"draw_bold_text_with_bright_colors\",\n" ++
        "    ])?;\n" ++
        "    assert_eq!(lines, vec![\n" ++
        "        String::from(\"hahahahahahahahaha [X]\"),\n" ++
        "        String::from(\"[MESSAGE TRUNCATED]   \")\n" ++
        "    ]);\n" ++
        "    foo(bar, |x| {\n" ++
        "        x + 1\n" ++
        "    });\n" ++
        "}\n";

    const wanted = "fn main() {\n" ++
        "    move_value(\n" ++
        "        &mut document,\n" ++
        "        &[\"draw_bold_text_with_bright_colors\"],\n" ++
        "        &[\"colors\", \"draw_bold_text_with_bright_colors\"],\n" ++
        "    )?;\n" ++
        "    assert_eq!(\n" ++
        "        lines,\n" ++
        "        vec![\n" ++
        "            String::from(\"hahahahahahahahaha [X]\"),\n" ++
        "            String::from(\"[MESSAGE TRUNCATED]   \")\n" ++
        "        ]\n" ++
        "    );\n" ++
        "    foo(bar, |x| x + 1);\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a short callee whose sole argument fits the call width takes no trailing comma" {
    const source = "fn f() {\n" ++
        "    import_paths.push(Err(\"Invalid import element type: expected path " ++
        "string\".into()));\n" ++
        "    import_paths.push(Err(\"Invalid import element type: expected path " ++
        "string_____\".into()));\n" ++
        "    import_paths.push(Err(\"Invalid import element type: expected path " ++
        "string_______\".into()));\n" ++
        "}\n";

    const wanted = "fn f() {\n" ++
        "    import_paths.push(Err(\n" ++
        "        \"Invalid import element type: expected path string\".into()\n" ++
        "    ));\n" ++
        "    import_paths.push(Err(\n" ++
        "        \"Invalid import element type: expected path " ++
        "string_____\".into(),\n" ++
        "    ));\n" ++
        "    import_paths.push(Err(\n" ++
        "        \"Invalid import element type: expected path " ++
        "string_______\".into(),\n" ++
        "    ));\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a macro body lays out its statements and keeps a block body's braces welded" {
    const source = "macro_rules! trigger {\n" ++
        "    (KeyBinding, $key:literal, $location:expr) => {{ " ++
        "BindingKey::Keycode { key: Key::Character($key.into()), location: " ++
        "$location } }};\n" ++
        "    (MouseBinding, MouseEvent::$event:ident,) => {{ MouseEvent::$event " ++
        "}};\n" ++
        "    ($a:expr, $b:expr) => {{ let x = $a; let y = $b; x + y }};\n" ++
        "    ($a:expr) => { if $a { let x = $a; x } else { $b } };\n" ++
        "}\n" ++
        "\n" ++
        "macro_rules! define_bignum {\n" ++
        "    ($name:ident) => {\n" ++
        "        impl $name {\n" ++
        "            pub fn from_u64(mut v: u64) -> $name {\n" ++
        "                while v > 0 {\n" ++
        "                    sz += 1;\n" ++
        "                }\n" ++
        "                $name { size: sz, base }\n" ++
        "            }\n" ++
        "        }\n" ++
        "    };\n" ++
        "}\n";

    const wanted = "macro_rules! trigger {\n" ++
        "    (KeyBinding, $key:literal, $location:expr) => {{\n" ++
        "        BindingKey::Keycode {\n" ++
        "            key: Key::Character($key.into()),\n" ++
        "            location: $location,\n" ++
        "        }\n" ++
        "    }};\n" ++
        "    (MouseBinding, MouseEvent::$event:ident,) => {{ MouseEvent::$event " ++
        "}};\n" ++
        "    ($a:expr, $b:expr) => {{\n" ++
        "        let x = $a;\n" ++
        "        let y = $b;\n" ++
        "        x + y\n" ++
        "    }};\n" ++
        "    ($a:expr) => {\n" ++
        "        if $a {\n" ++
        "            let x = $a;\n" ++
        "            x\n" ++
        "        } else {\n" ++
        "            $b\n" ++
        "        }\n" ++
        "    };\n" ++
        "}\n" ++
        "\n" ++
        "macro_rules! define_bignum {\n" ++
        "    ($name:ident) => {\n" ++
        "        impl $name {\n" ++
        "            pub fn from_u64(mut v: u64) -> $name {\n" ++
        "                while v > 0 {\n" ++
        "                    sz += 1;\n" ++
        "                }\n" ++
        "                $name { size: sz, base }\n" ++
        "            }\n" ++
        "        }\n" ++
        "    };\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a match arm pattern reserves room for its arrow" {
    const source = "fn f() {\n" ++
        "    match x {\n" ++
        "        Ok(event) => match event.kind {\n" ++
        "            Ok(x) => match x {\n" ++
        "                Ok(y) => match y {\n" ++
        "                    Ok(z) => match z {\n" ++
        "                        EventKind::Modify(ModifyKind::Name(\n" ++
        "                            RenameMode::From | RenameMode::Both,\n" ++
        "                        )) => (),\n" ++
        "                        _ => (),\n" ++
        "                    },\n" ++
        "                },\n" ++
        "            },\n" ++
        "        },\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a sole call argument under a try operator still overflows" {
    const source = "impl<'de> Deserialize<'de> for MouseBindings {\n" ++
        "    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>\n" ++
        "    where\n" ++
        "        D: Deserializer<'de>,\n" ++
        "    {\n" ++
        "        Ok(Self(ui_config::deserialize_bindings(deserializer, " ++
        "Self::default().0)?))\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "impl<'de> Deserialize<'de> for MouseBindings {\n" ++
        "    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>\n" ++
        "    where\n" ++
        "        D: Deserializer<'de>,\n" ++
        "    {\n" ++
        "        Ok(Self(ui_config::deserialize_bindings(\n" ++
        "            deserializer,\n" ++
        "            Self::default().0,\n" ++
        "        )?))\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "an or-pattern alternative after a multi-line one starts its own line" {
    const source = "fn derive(input: TokenStream) -> TokenStream {\n" ++
        "    match input.data {\n" ++
        "        Data::Struct(DataStruct { fields: Fields::Unnamed(_), .. }) | " ++
        "Data::Enum(_) => {\n" ++
        "            derive_direct(input.ident, input.generics).into()\n" ++
        "        },\n" ++
        "        Data::Struct(DataStruct { fields: Fields::Named(fields), .. }) " ++
        "=> {\n" ++
        "            derive_recursive(input.ident, input.generics, " ++
        "fields.named).into()\n" ++
        "        },\n" ++
        "        _ => Error::new(input.ident.span(), " ++
        "UNSUPPORTED_ERROR).to_compile_error().into(),\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "fn derive(input: TokenStream) -> TokenStream {\n" ++
        "    match input.data {\n" ++
        "        Data::Struct(DataStruct {\n" ++
        "            fields: Fields::Unnamed(_),\n" ++
        "            ..\n" ++
        "        })\n" ++
        "        | Data::Enum(_) => derive_direct(input.ident, " ++
        "input.generics).into(),\n" ++
        "        Data::Struct(DataStruct {\n" ++
        "            fields: Fields::Named(fields),\n" ++
        "            ..\n" ++
        "        }) => derive_recursive(input.ident, input.generics, " ++
        "fields.named).into(),\n" ++
        "        _ => Error::new(input.ident.span(), UNSUPPORTED_ERROR)\n" ++
        "            .to_compile_error()\n" ++
        "            .into(),\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a closure reached through sole call arguments counts toward the chain width" {
    const source = "impl X {\n" ++
        "    fn text_area_size_pixels(&mut self) {\n" ++
        "        " ++
        "self.event_proxy.send_event(Event::TextAreaSizeRequest(Arc::new(move " ++
        "|window_size| {\n" ++
        "            let height = window_size.num_lines * " ++
        "window_size.cell_height;\n" ++
        "            let width = window_size.num_cols * window_size.cell_width;\n" ++
        "            format!(\"\\x1b[4;{height};{width}t\")\n" ++
        "        })));\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "impl X {\n" ++
        "    fn text_area_size_pixels(&mut self) {\n" ++
        "        self.event_proxy\n" ++
        "            .send_event(Event::TextAreaSizeRequest(Arc::new(move " ++
        "|window_size| {\n" ++
        "                let height = window_size.num_lines * " ++
        "window_size.cell_height;\n" ++
        "                let width = window_size.num_cols * " ++
        "window_size.cell_width;\n" ++
        "                format!(\"\\x1b[4;{height};{width}t\")\n" ++
        "            })));\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a brace macro written over lines is a hugged last argument of its chain" {
    const source = "fn f() {\n" ++
        "    for x in y {\n" ++
        "        if z {\n" ++
        "            generics.phantoms.extend(quote! {\n" ++
        "                #ident : std::marker::PhantomData < #ident >,\n" ++
        "            });\n" ++
        "        }\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a logical operand holding a chain past the chain width breaks the operators first" {
    const source = "fn f() {\n" ++
        "    if vi_mode && self.terminal.selection.as_ref().is_some_and(|s| " ++
        "!s.is_empty()) {\n" ++
        "        x();\n" ++
        "    }\n" ++
        "    let y = vi_mode && self.terminal.selection.as_ref().is_some_and(|s| " ++
        "!s.is_empty());\n" ++
        "    if len > 0 && wrapped[len - " ++
        "1].flags().contains(Flags::LEADING_WIDE_CHAR_SPACER_LONGER) {\n" ++
        "        x();\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "fn f() {\n" ++
        "    if vi_mode\n" ++
        "        && self\n" ++
        "            .terminal\n" ++
        "            .selection\n" ++
        "            .as_ref()\n" ++
        "            .is_some_and(|s| !s.is_empty())\n" ++
        "    {\n" ++
        "        x();\n" ++
        "    }\n" ++
        "    let y = vi_mode\n" ++
        "        && self\n" ++
        "            .terminal\n" ++
        "            .selection\n" ++
        "            .as_ref()\n" ++
        "            .is_some_and(|s| !s.is_empty());\n" ++
        "    if len > 0\n" ++
        "        && wrapped[len - 1]\n" ++
        "            .flags()\n" ++
        "            .contains(Flags::LEADING_WIDE_CHAR_SPACER_LONGER)\n" ++
        "    {\n" ++
        "        x();\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a chain past the chain width inside a condition's body leaves the condition joined" {
    const source = "fn f() {\n" ++
        "    if t.is_ppc64be() || t.no_os() {\n" ++
        "        // comment\n" ++
        "        " ++
        "assert.success().stdout(foo).something_else(bar).and_more_things_here(x)" ++
        ";\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "fn f() {\n" ++
        "    if t.is_ppc64be() || t.no_os() {\n" ++
        "        // comment\n" ++
        "        assert\n" ++
        "            .success()\n" ++
        "            .stdout(foo)\n" ++
        "            .something_else(bar)\n" ++
        "            .and_more_things_here(x);\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "an assignment joins a vertical chain whose last call breaks its arguments" {
    const source = "fn f() {\n" ++
        "    let surface_attributes =\n" ++
        "        " ++
        "SurfaceAttributesBuilder::<WindowSurface>::new().with_srgb(Some(false))." ++
        "build(\n" ++
        "            raw_window_handle,\n" ++
        "            NonZeroU32::new(size.width).unwrap(),\n" ++
        "            NonZeroU32::new(size.height).unwrap(),\n" ++
        "        );\n" ++
        "}\n";

    const wanted = "fn f() {\n" ++
        "    let surface_attributes = " ++
        "SurfaceAttributesBuilder::<WindowSurface>::new()\n" ++
        "        .with_srgb(Some(false))\n" ++
        "        .build(\n" ++
        "            raw_window_handle,\n" ++
        "            NonZeroU32::new(size.width).unwrap(),\n" ++
        "            NonZeroU32::new(size.height).unwrap(),\n" ++
        "        );\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a frontmatter keeps its bytes and the blank lines around it" {
    const source = "#!/usr/bin/env cargo\n\n\n" ++
        "---cargo\n" ++
        "[dependencies]\n" ++
        "use b;\n" ++
        "use a;\n" ++
        "---\n\n\n\n" ++
        "use b;\n" ++
        "use a;\n" ++
        "fn main(){}\n";

    const wanted = "#!/usr/bin/env cargo\n\n\n" ++
        "---cargo\n" ++
        "[dependencies]\n" ++
        "use b;\n" ++
        "use a;\n" ++
        "---\n\n\n\n" ++
        "use a;\n" ++
        "use b;\n" ++
        "fn main() {}\n";

    try expect_formatted(source, wanted);
}

test "an attribute glues its hash, bang and bracket" {
    const source = "# ! [allow(dead_code)]\n" ++
        "# [derive(Debug)]\n" ++
        "struct S;\n";

    const wanted = "#![allow(dead_code)]\n" ++
        "#[derive(Debug)]\n" ++
        "struct S;\n";

    try expect_formatted(source, wanted);
}

test "a flattened arm ending in a try operator leaves the next arm at its level" {
    const source = "fn f() {\n" ++
        "    match x {\n" ++
        "        A => {\n" ++
        "            a.b()?\n" ++
        "        }\n" ++
        "        B => c,\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "fn f() {\n" ++
        "    match x {\n" ++
        "        A => a.b()?,\n" ++
        "        B => c,\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a chain ending in a try operator counts it three times against its arm" {
    const source = "fn f() {\n" ++
        "    for x in y {\n" ++
        "        match x {\n" ++
        "            FileContents::Generated(generated_kind) => {\n" ++
        "                let contents = match generated_kind {\n" ++
        "                    GeneratedFile::Manifest(_) => {\n" ++
        "                        publish_pkg.manifest().to_normalized_contents()?\n" ++
        "                    }\n" ++
        "                    GeneratedFile::Lockfile(_) => " ++
        "build_lock(ws, opts, &publish_pkg, local_reg)?,\n" ++
        "                };\n" ++
        "            }\n" ++
        "        }\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a carriage return before a line feed leaves the frontmatter with the rest of the file" {
    const source = "---\r\n[package]\r\n---\r\nfn main() {}\r\n";
    const wanted = "---\n[package]\n---\nfn main() {}\n";

    try expect_formatted(source, wanted);
}

test "a file with nothing but blanks prints one line feed" {
    const gpa = std.testing.allocator;
    var held: Held = undefined;

    try held.init(gpa);
    defer held.deinit(gpa);

    var out: Buffer = try .init(gpa, out_bytes_max);
    defer out.deinit(gpa);

    try held.format("", &out);
    try std.testing.expectEqualStrings("\n", out.const_slice());
    try expect_formatted(" \t\n\n", "\n");
}

test "a use list behind an inner attribute keeps two columns of its line free" {
    const source = "#![allow(clippy::disallowed_types)]\n" ++
        "\n" ++
        "use cargo_credential::{\n" ++
        "    Action, CacheControl, Credential, CredentialResponse, RegistryInfo, Secret,\n" ++
        "};\n" ++
        "use std::{collections::HashMap, fs::File, io::ErrorKind};\n";

    try expect_formatted(source, source);
}

test "a signature past the width breaks its parameters before a return type's arguments" {
    const source = "fn rfind() {\n" ++
        "    #[inline]\n" ++
        "    fn check<T>(mut predicate_value: impl FnMut(&T) -> bool) -> " ++
        "impl FnMut((), T) -> ControlFlow<T> {\n" ++
        "        move |(), x| x\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "fn rfind() {\n" ++
        "    #[inline]\n" ++
        "    fn check<T>(\n" ++
        "        mut predicate_value: impl FnMut(&T) -> bool,\n" ++
        "    ) -> impl FnMut((), T) -> ControlFlow<T> {\n" ++
        "        move |(), x| x\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a let else that leaves its line starts the else at the statement's level" {
    const source = "fn f() {\n" ++
        "    for (dep_pkg_id, deps) in state.deps(unit, unit_for) {\n" ++
        "        let Some(dep_lib) = " ++
        "calc_artifact_deps(unit, unit_for, dep_pkg_id, &deps, state, &mut ret)?\n" ++
        "        else {\n" ++
        "            continue;\n" ++
        "        };\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a struct rest inside macro arguments is an item of its literal" {
    const source = "fn f() {\n" ++
        "    matches!(*self, CompileFilter::Only { all_targets: true, .. });\n" ++
        "}\n";

    const wanted = "fn f() {\n" ++
        "    matches!(\n" ++
        "        *self,\n" ++
        "        CompileFilter::Only {\n" ++
        "            all_targets: true,\n" ++
        "            ..\n" ++
        "        }\n" ++
        "    );\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a link after a block-like chain root measures from the root's own column" {
    const source = "fn f() {\n" ++
        "    {\n" ++
        "        clip.add_curve(\n" ++
        "            id,\n" ++
        "            AnimatableCurve::new(\n" ++
        "                animated_field!(UiTransform::rotation),\n" ++
        "                AnimatableKeyframeCurve::new(\n" ++
        "                    [0.0, 1.0, 2.0, 3.0]\n" ++
        "                        .into_iter()\n" ++
        "                        .zip([0., TAU / 3., TAU / 1.5, TAU].map(Rot2::radians)),\n" ++
        "                )\n" ++
        "                .expect(\"should be able to build rotation curve " ++
        "because we pass in valid samples\"),\n" ++
        "            ),\n" ++
        "        );\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a link after a block-like chain root counts the separator that follows the chain" {
    const source = "fn f() {\n" ++
        "    {\n" ++
        "        clip.add_curve(\n" ++
        "            id,\n" ++
        "            AnimatableCurve::new(\n" ++
        "                animated_field!(UiTransform::rotation),\n" ++
        "                AnimatableKeyframeCurve::new(\n" ++
        "                    [0.0, 1.0, 2.0, 3.0]\n" ++
        "                        .into_iter()\n" ++
        "                        .zip([0., TAU / 3., TAU / 1.5, TAU].map(Rot2::radians)),\n" ++
        "                )\n" ++
        "                .expect(\"should be able to build rotation curve " ++
        "because we pass in valid samplesxx\"),\n" ++
        "            ),\n" ++
        "        );\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "fn f() {\n" ++
        "    {\n" ++
        "        clip.add_curve(\n" ++
        "            id,\n" ++
        "            AnimatableCurve::new(\n" ++
        "                animated_field!(UiTransform::rotation),\n" ++
        "                AnimatableKeyframeCurve::new(\n" ++
        "                    [0.0, 1.0, 2.0, 3.0]\n" ++
        "                        .into_iter()\n" ++
        "                        .zip([0., TAU / 3., TAU / 1.5, TAU].map(Rot2::radians)),\n" ++
        "                )\n" ++
        "                .expect(\n" ++
        "                    \"should be able to build rotation curve " ++
        "because we pass in valid samplesxx\",\n" ++
        "                ),\n" ++
        "            ),\n" ++
        "        );\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a chain that moves to its own argument line is measured from that line" {
    const source = "pub fn load_assets() {\n" ++
        "    let road_straight =\n" ++
        "        load_asset!(GltfAssetLabel::Scene(0)\n" ++
        "            .from_asset(format!(\"{base_url}/city-kit-roads/road-straight.glb\")));\n" ++
        "}\n";

    const wanted = "pub fn load_assets() {\n" ++
        "    let road_straight = load_asset!(\n" ++
        "        GltfAssetLabel::Scene(0)" ++
        ".from_asset(format!(\"{base_url}/city-kit-roads/road-straight.glb\"))\n" ++
        "    );\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a comma inside a turbofish does not make a sole argument a list" {
    const source = "fn f() {\n" ++
        "    {\n" ++
        "        app.add_plugins(" ++
        "ExtractComponentPlugin::<RenderComponent, ExtractApp>::default());\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a tuple pattern takes the line width, not the call width" {
    const source = "fn f() {\n" ++
        "    {\n" ++
        "        {\n" ++
        "            let Ok((mut skybox_transform, mut skybox_projection, " ++
        "mut skybox_camera)) =\n" ++
        "                skybox_cams.get_mut(skybox_entity)\n" ++
        "            else {\n" ++
        "                return;\n" ++
        "            };\n" ++
        "            if let Ok((button_ent, variant, disabled, pressed, " ++
        "hovered, bg_color, font)) =\n" ++
        "                q_buttons.get_mut(entity)\n" ++
        "            {\n" ++
        "                x();\n" ++
        "            }\n" ++
        "        }\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a nested import list past the list width breaks and fills its items" {
    const source = "mod tests {\n" ++
        "    use crate::{\n" ++
        "        Asset, AssetApp, AssetServer, Assets, Handle, LoadState, ReflectAsset,\n" ++
        "        common_loaders::ron::{RonLoader, RonSaver, RonSaverSettings, " ++
        "TypedRonLoader, TypedRonSaver},\n" ++
        "        saver::{SavedAsset, save_using_saver},\n" ++
        "    };\n" ++
        "}\n";

    const wanted = "mod tests {\n" ++
        "    use crate::{\n" ++
        "        Asset, AssetApp, AssetServer, Assets, Handle, LoadState, ReflectAsset,\n" ++
        "        common_loaders::ron::{\n" ++
        "            RonLoader, RonSaver, RonSaverSettings, TypedRonLoader, TypedRonSaver,\n" ++
        "        },\n" ++
        "        saver::{SavedAsset, save_using_saver},\n" ++
        "    };\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "closure parameters past the first line align under the first parameter" {
    const source = "fn f() {\n" ++
        "    app.add_systems(\n" ++
        "        Last,\n" ++
        "        move |mut hot_patched_writer: MessageWriter<HotPatched>,\n" ++
        "              mut res: ResMut<HotPatchChanges>| {\n" ++
        "            res.set_changed();\n" ++
        "        },\n" ++
        "    );\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a comma between closure parameters separates no struct field" {
    const source = "impl X for Y {\n" ++
        "    fn create(_input: ()) -> Self {\n" ++
        "        Self {\n" ++
        "            de: |deserializer, registry| {\n" ++
        "                Ok(Box::new(T::deserialize(deserializer, registry)?))\n" ++
        "            },\n" ++
        "        }\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "impl X for Y {\n" ++
        "    fn create(_input: ()) -> Self {\n" ++
        "        Self {\n" ++
        "            de: |deserializer, registry| " ++
        "Ok(Box::new(T::deserialize(deserializer, registry)?)),\n" ++
        "        }\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a parenthesized closure takes no tuple comma and keeps its links at its level" {
    const source = "fn f() {\n" ++
        "    world.add_observer(\n" ++
        "        (|_: On<EventA>, mut order: ResMut<Order>| {\n" ++
        "            order.observed(\"event\");\n" ++
        "        })\n" ++
        "        .run_if(|flag: Res<RunConditionFlag>| flag.0),\n" ++
        "    );\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a closure's tuple body is measured inside its parentheses" {
    const source = "fn f() {\n" ++
        "    let inputs: &[fn() -> (Box<dyn Struct>, Box<dyn PartialReflect>)] = &[\n" ++
        "        || (Box::new(Struct16::default()), Box::new(Struct16::default())),\n" ++
        "        || {\n" ++
        "            (\n" ++
        "                Box::new(Struct128::default()),\n" ++
        "                Box::new(Struct128::default()),\n" ++
        "            )\n" ++
        "        },\n" ++
        "    ];\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a let chain operand after a broken let starts at the condition's level" {
    const source = "fn f() {\n" ++
        "    if let (Some(skybox_pipeline), Some(SkyboxBindGroup(skybox_bind_group))) =\n" ++
        "        (skybox_pipeline, skybox_bind_group)\n" ++
        "        && let Some(pipeline) = pipeline_cache.get_render_pipeline(skybox_pipeline.0)\n" ++
        "    {\n" ++
        "        render_pass.set_render_pipeline(pipeline);\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a blank line between fn parameters is kept and one between call arguments is not" {
    const source = "fn handle(\n" ++
        "    value_change: On<ValueChange<f32>>,\n" ++
        "    number_input_q: Query<&ClipNode, With<FeathersNumberInput>>,\n" ++
        "\n" ++
        "    mut commands: Commands,\n" ++
        ") {\n" ++
        "    foo(\n" ++
        "        aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa,\n" ++
        "        bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb,\n" ++
        "\n" ++
        "        ccccccccccccccccccccccccccccccccc,\n" ++
        "    );\n" ++
        "}\n";

    const wanted = "fn handle(\n" ++
        "    value_change: On<ValueChange<f32>>,\n" ++
        "    number_input_q: Query<&ClipNode, With<FeathersNumberInput>>,\n" ++
        "\n" ++
        "    mut commands: Commands,\n" ++
        ") {\n" ++
        "    foo(\n" ++
        "        aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa,\n" ++
        "        bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb,\n" ++
        "        ccccccccccccccccccccccccccccccccc,\n" ++
        "    );\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a struct pattern after if let is no branch body" {
    const source = "fn f() {\n" ++
        "    if let CurrentMotion::UserControlled { anchor, .. } = &self.current_motion {\n" ++
        "        x();\n" ++
        "    }\n" ++
        "    if let TabDragPhase::Completed { drop: Some(drop) } = phase {\n" ++
        "        x();\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a comment between chain links keeps every link on its own line" {
    const source = "fn f() {\n" ++
        "    commands\n" ++
        "        .spawn((\n" ++
        "            Mesh3d(meshes.add(Cuboid::new(0.5, 0.5, 0.5))),\n" ++
        "            MeshMaterial3d(materials.add(Color::srgb_u8(124, 144, 255))),\n" ++
        "        ))\n" ++
        "        // With the MeshPickingPlugin added\n" ++
        "        .observe(on_drag_rotate);\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a link after a broken turbofish link stays at the chain's level" {
    const source = "fn main() {\n" ++
        "    App::new()\n" ++
        "        .add_plugins(DefaultPlugins)\n" ++
        "        .add_plugins(MaterialPlugin::<\n" ++
        "            ExtendedMaterial<StandardMaterial, MyExtension>,\n" ++
        "        >::default())\n" ++
        "        .add_systems(Startup, setup)\n" ++
        "        .run();\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "an assignment keeps a chain that parts at its links on the equals line" {
    const source = "fn f() {\n" ++
        "    {\n" ++
        "        let blending_weight_calculation_pipeline_id = specialized_render_pipelines\n" ++
        "            .blending_weight_calculation\n" ++
        "            .specialize(\n" ++
        "                &pipeline_cache,\n" ++
        "                &smaa_pipelines.blending_weight_calculation,\n" ++
        "                smaa.preset,\n" ++
        "            );\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a macro argument ending in a comparison with no right side is kept verbatim" {
    const source = "impl_reflect_for_hashset!(::std::collections::HashSet<V,S>);\n" ++
        "with_api!(\n" ++
        "    define_dispatcher,\n" ++
        "    MarkedTokenStream<S>,\n" ++
        "    MarkedSpan<S>,\n" ++
        "    MarkedSymbol<S>,\n" ++
        "    AnotherLongTypeName<S>\n" ++
        ");\n";

    try expect_formatted(source, source);
}

test "trailing comments of a list's first items align past the widest item" {
    const source = "fn get(z_near: f32) -> [Vec3A; 4] {\n" ++
        "    [\n" ++
        "        Vec3A::new(a * aspect_ratio, -a, z_near),  // bottom right\n" ++
        "        Vec3A::new(a * aspect_ratio, a, z_near),   // top right\n" ++
        "        Vec3A::new(-a * aspect_ratio, a, z_near),  // top left\n" ++
        "        Vec3A::new(-a * aspect_ratio, -a, z_near), // bottom left\n" ++
        "    ]\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "a blank line beside an inner doc comment among inner attributes is kept" {
    const source = "#![no_std]\n" ++
        "\n" ++
        "//! A UI-centric focus system for Bevy.\n" ++
        "#![cfg_attr(feature = \"bevy_picking\", doc = \"x\")]\n" ++
        "//!\n" ++
        "//! This crate.\n" ++
        "\n" ++
        "extern crate alloc;\n";

    try expect_formatted(source, source);
}

test "impl generics that fit join and the trait takes its own line" {
    const source = "impl<\n" ++
        "        C: ExtractComponent<L, F>,\n" ++
        "        L: AppLabel + Default + Clone + Copy + Eq,\n" ++
        "        F: 'static + Send + Sync,\n" ++
        "    > Plugin for ExtractComponentPlugin<C, L, F>\n" ++
        "{\n" ++
        "    fn build(&self, app: &mut App) {}\n" ++
        "}\n";

    const wanted = "impl<C: ExtractComponent<L, F>, L: AppLabel + Default + Clone + Copy + Eq, " ++
        "F: 'static + Send + Sync>\n" ++
        "    Plugin for ExtractComponentPlugin<C, L, F>\n" ++
        "{\n" ++
        "    fn build(&self, app: &mut App) {}\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a sole closure argument hugs its call while its head fits the line" {
    const source = "fn f() {\n" ++
        "    {\n" ++
        "        app.add_observer(|trigger: On<FocusGained>, mut log: ResMut<FocusEventLog>| {\n" ++
        "            log.0.push(FocusEvent::Gained(trigger.entity));\n" ++
        "        });\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, source);
}

test "an import item holding a nested list breaks and its wide nested list breaks too" {
    const source = "use bevy_render::{\n" ++
        "    Extract, ExtractSchedule,\n" ++
        "    mesh::{\n" ++
        "        RenderMesh, RenderMeshBufferInfo,\n" ++
        "        allocator::{MeshAllocator, MeshAllocatorSettings, MeshSlabs},\n" ++
        "    },\n" ++
        "    render_asset::{PrepareAssetError, RenderAsset, RenderAssetPlugin, " ++
        "RenderAssets, prepare_assets},\n" ++
        "};\n";

    const wanted = "use bevy_render::{\n" ++
        "    Extract, ExtractSchedule,\n" ++
        "    mesh::{\n" ++
        "        RenderMesh, RenderMeshBufferInfo,\n" ++
        "        allocator::{MeshAllocator, MeshAllocatorSettings, MeshSlabs},\n" ++
        "    },\n" ++
        "    render_asset::{\n" ++
        "        PrepareAssetError, RenderAsset, RenderAssetPlugin, " ++
        "RenderAssets, prepare_assets,\n" ++
        "    },\n" ++
        "};\n";

    try expect_formatted(source, wanted);
}

test "a chain that is the argument of a flattened arm body is seated on the arm's argument line" {
    const source = "fn f() {\n" ++
        "    match x {\n" ++
        "        WindowPosition::At(position) => {\n" ++
        "            Some(PhysicalPositionAbcdefghijk::new(position[0] as f64, " ++
        "position[1] as f64).cast::<i32>())\n" ++
        "        }\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "fn f() {\n" ++
        "    match x {\n" ++
        "        WindowPosition::At(position) => Some(\n" ++
        "            PhysicalPositionAbcdefghijk::new(position[0] as f64, " ++
        "position[1] as f64).cast::<i32>(),\n" ++
        "        ),\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "an arm after a flattened block arm keeps its level when it opens with a reference" {
    const source = "fn f() {\n" ++
        "    match self {\n" ++
        "        &Origin::File { declaration, declaration_tree_id, .. } => {\n" ++
        "            Some(AstId::new(declaration_tree_id.file_id(), declaration))\n" ++
        "        }\n" ++
        "        &Origin::Inline { definition, definition_tree_id } => {\n" ++
        "            Some(AstId::new(definition_tree_id.file_id(), definition))\n" ++
        "        }\n" ++
        "        Origin::CrateRoot { .. } | Origin::BlockExpr { .. } => None,\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "fn f() {\n" ++
        "    match self {\n" ++
        "        &Origin::File {\n" ++
        "            declaration,\n" ++
        "            declaration_tree_id,\n" ++
        "            ..\n" ++
        "        } => Some(AstId::new(declaration_tree_id.file_id(), declaration)),\n" ++
        "        &Origin::Inline {\n" ++
        "            definition,\n" ++
        "            definition_tree_id,\n" ++
        "        } => Some(AstId::new(definition_tree_id.file_id(), definition)),\n" ++
        "        Origin::CrateRoot { .. } | Origin::BlockExpr { .. } => None,\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a chain after an if-let equals breaks at its first link" {
    const source = "fn f() {\n" ++
        "    if self.demand_eqtype(pat.into(), expected, pat_ty).is_err() {\n" ++
        "        let expected = if let TyKind::Tuple(tys) =\n" ++
        "            self.table.try_structurally_resolve_type(Span::Dummy, expected).kind()\n" ++
        "        {\n" ++
        "            tys\n" ++
        "        } else {\n" ++
        "            expected\n" ++
        "        };\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "fn f() {\n" ++
        "    if self.demand_eqtype(pat.into(), expected, pat_ty).is_err() {\n" ++
        "        let expected = if let TyKind::Tuple(tys) = self\n" ++
        "            .table\n" ++
        "            .try_structurally_resolve_type(Span::Dummy, expected)\n" ++
        "            .kind()\n" ++
        "        {\n" ++
        "            tys\n" ++
        "        } else {\n" ++
        "            expected\n" ++
        "        };\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "an arm whose call argument is an if-else that must break flattens onto the arrow" {
    const source = "fn f() {\n" ++
        "    if !it.parent_enum(db).is_data_carrying(db) {\n" ++
        "        match it.eval(db) {\n" ++
        "            Ok(it) => {\n" ++
        "                Some(if it >= 10 { format!(\"{it} ({it:#X})\") } else { format!(\"{it}" ++
        "\") })\n" ++
        "            }\n" ++
        "            Err(err) => None,\n" ++
        "        }\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "fn f() {\n" ++
        "    if !it.parent_enum(db).is_data_carrying(db) {\n" ++
        "        match it.eval(db) {\n" ++
        "            Ok(it) => Some(if it >= 10 {\n" ++
        "                format!(\"{it} ({it:#X})\")\n" ++
        "            } else {\n" ++
        "                format!(\"{it}\")\n" ++
        "            }),\n" ++
        "            Err(err) => None,\n" ++
        "        }\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a block arm written on one line with the next arm ends its line" {
    const source = "fn f() {\n" ++
        "    match x { 1 => { }, _ => panic!(\"wat\") }\n" ++
        "}\n";

    const wanted = "fn f() {\n" ++
        "    match x {\n" ++
        "        1 => {}\n" ++
        "        _ => panic!(\"wat\"),\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}

test "a match on a block scrutinee breaks its arms" {
    const source = "fn f() {\n" ++
        "    match { } { _ => () };\n" ++
        "}\n";

    const wanted = "fn f() {\n" ++
        "    match {} {\n" ++
        "        _ => (),\n" ++
        "    };\n" ++
        "}\n";

    try expect_formatted(source, wanted);
}
