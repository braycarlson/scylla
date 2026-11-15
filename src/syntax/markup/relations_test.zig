const std = @import("std");
const assert = std.debug.assert;
const Kind = @import("kind.zig").Kind;
const Token = @import("token.zig").Token;
const Tokens = @import("tokens.zig").Tokens;
const corpus = @import("../../testing/corpus.zig");
const lexer = @import("lex.zig");
const markup_testing = @import("../testing/markup.zig");

const Scratch = struct {
    plain: std.ArrayList(Token),
    source: std.ArrayList(u8),
    tokens: Tokens,

    fn init(scratch: *Scratch, gpa: std.mem.Allocator) !void {
        scratch.tokens = try .init(gpa, token_count_max);
        scratch.plain = .empty;
        scratch.source = .empty;

        assert(scratch.tokens.count() == 0);
    }

    fn deinit(scratch: *Scratch, gpa: std.mem.Allocator) void {
        scratch.source.deinit(gpa);
        scratch.plain.deinit(gpa);
        scratch.tokens.deinit(gpa);
        scratch.* = undefined;
    }

    fn lexed(scratch: *Scratch, source: []const u8) ![]const Token {
        assert(source.len <= std.math.maxInt(u32));

        try lexer.lex_with(source, &scratch.tokens, &markup_testing.raw_text_tags);

        const held = scratch.tokens.slice();

        assert(held.len <= token_count_max);

        return held;
    }

    fn plain_lexed(scratch: *Scratch, gpa: std.mem.Allocator, source: []const u8) ![]const Token {
        assert(source.len <= std.math.maxInt(u32));

        const held = try scratch.lexed(source);

        scratch.plain.clearRetainingCapacity();

        try scratch.plain.appendSlice(gpa, held);

        assert(scratch.plain.items.len == held.len);

        return scratch.plain.items;
    }
};

const fixture_root = "tests/fixtures/templates";
const mark = [_]u8{ 0xef, 0xbb, 0xbf };
const note = "{# note #}";
const source_bytes_max: u32 = 1 << 28;
const token_count_max: u32 = 1 << 18;

fn fixtures_collected(gpa: std.mem.Allocator) !corpus.Files {
    var files = try corpus.collect(
        gpa,
        fixture_root,
        source_bytes_max,
        markup_testing.template_selected,
    );

    errdefer files.deinit(gpa);

    if (files.slice().len == 0) {
        std.debug.print("no fixture templates under {s}\n", .{fixture_root});

        return error.TestUnexpectedResult;
    }

    return files;
}

fn expect_fixture(held: bool, name: []const u8, comptime message: []const u8) !void {
    assert(name.len > 0);
    assert(message.len > 0);

    if (held) return;

    std.debug.print("{s}: " ++ message ++ "\n", .{name});

    return error.TestUnexpectedResult;
}

fn expect_token(held: bool, name: []const u8, comptime message: []const u8, index: usize) !void {
    assert(name.len > 0);
    assert(message.len > 0);
    assert(index < std.math.maxInt(u32));

    if (held) return;

    std.debug.print("{s}: token {d} " ++ message ++ "\n", .{ name, index });

    return error.TestUnexpectedResult;
}

fn mark_relation(gpa: std.mem.Allocator, scratch: *Scratch, file: *const corpus.File) !void {
    const plain = try scratch.plain_lexed(gpa, file.source);

    scratch.source.clearRetainingCapacity();

    try scratch.source.appendSlice(gpa, &mark);
    try scratch.source.appendSlice(gpa, file.source);

    const marked = try scratch.lexed(scratch.source.items);

    try expect_fixture(marked.len >= plain.len, file.name, "the mark dropped tokens");

    const extra = marked.len - plain.len;

    try expect_fixture(extra <= 1, file.name, "the mark added more than one token");

    for (0..plain.len -| 1) |index| {
        const before = plain[plain.len - 1 - index];
        const after = marked[marked.len - 1 - index];

        try expect_token(
            before.kind == after.kind,
            file.name,
            "from the end changed kind behind the mark",
            index,
        );

        try expect_token(
            before.offset + 3 == after.offset,
            file.name,
            "from the end is not three bytes further along",
            index,
        );
    }

    if (extra == 1) {
        try expect_fixture(
            marked[0].kind == .text,
            file.name,
            "the mark opened a token that is not text",
        );
    }
}

fn windows_relation(gpa: std.mem.Allocator, scratch: *Scratch, file: *const corpus.File) !void {
    assert(std.mem.findScalar(u8, file.source, '\r') == null);

    const plain = try scratch.plain_lexed(gpa, file.source);

    scratch.source.clearRetainingCapacity();

    for (file.source) |byte| {
        if (byte == '\n') try scratch.source.append(gpa, '\r');

        try scratch.source.append(gpa, byte);
    }

    const carried = try scratch.lexed(scratch.source.items);
    var same = plain.len == carried.len;

    for (plain, 0..) |held, index| {
        if (index >= carried.len) break;

        if (held.kind != carried[index].kind) same = false;
    }

    try expect_fixture(same, file.name, "the carriage returns changed the token kinds");
}

fn note_relation(gpa: std.mem.Allocator, scratch: *Scratch, file: *const corpus.File) !bool {
    const plain = try scratch.plain_lexed(gpa, file.source);
    const at = boundary(plain) orelse return false;

    scratch.source.clearRetainingCapacity();

    try scratch.source.appendSlice(gpa, file.source[0..at]);
    try scratch.source.appendSlice(gpa, note);
    try scratch.source.appendSlice(gpa, file.source[at..]);

    const carried = try scratch.lexed(scratch.source.items);

    try expect_fixture(
        carried.len == plain.len + 3,
        file.name,
        "the comment did not add three tokens",
    );

    var head: usize = 0;

    for (plain, 0..) |held, index| {
        if (held.offset == at) {
            head = index;

            break;
        }
    }

    try expect_fixture(
        carried[head].kind == .comment_open,
        file.name,
        "the comment did not open where it was inserted",
    );

    try std.testing.expectEqual(Kind.comment_text, carried[head + 1].kind);
    try std.testing.expectEqual(Kind.comment_close, carried[head + 2].kind);
    try note_tokens_compared(plain, carried, head, file.name);

    return true;
}

fn note_tokens_compared(
    plain: []const Token,
    carried: []const Token,
    head: usize,
    name: []const u8,
) !void {
    assert(carried.len == plain.len + 3);
    assert(head < plain.len);
    assert(name.len > 0);

    for (plain[0..head], carried[0..head], 0..) |before, after, index| {
        try expect_token(std.meta.eql(before, after), name, "before the comment moved", index);
    }

    for (plain[head..], carried[head + 3 ..], 0..) |before, after, index| {
        try expect_token(
            before.kind == after.kind,
            name,
            "after the comment changed kind",
            index,
        );

        try expect_token(
            before.offset + note.len == after.offset,
            name,
            "after the comment is not ten bytes further along",
            index,
        );
    }
}

fn boundary(tokens: []const Token) ?u32 {
    assert(tokens.len <= token_count_max);

    for (tokens, 0..) |held, index| {
        if (held.kind != .angle_close) continue;
        if (index + 1 >= tokens.len) continue;

        const next = tokens[index + 1];

        switch (next.kind) {
            .angle_open, .angle_open_slash, .text => return next.offset,
            else => continue,
        }
    }

    return null;
}

test "a mark prepended shifts every token and changes no kind" {
    const gpa = std.testing.allocator;
    var scratch: Scratch = undefined;

    try scratch.init(gpa);
    defer scratch.deinit(gpa);

    var files = try fixtures_collected(gpa);
    defer files.deinit(gpa);

    var compared: u32 = 0;

    for (files.slice()) |*file| {
        try mark_relation(gpa, &scratch, file);

        compared += 1;
    }

    if (compared <= 300) std.debug.print("the corpus lost its fixtures\n", .{});

    try std.testing.expect(compared > 300);
}

test "windows line endings change no token kind" {
    const gpa = std.testing.allocator;
    var scratch: Scratch = undefined;

    try scratch.init(gpa);
    defer scratch.deinit(gpa);

    var files = try fixtures_collected(gpa);
    defer files.deinit(gpa);

    for (files.slice()) |*file| {
        if (std.mem.findScalar(u8, file.source, '\r') != null) continue;

        try windows_relation(gpa, &scratch, file);
    }
}

test "a comment inserted at a tag boundary adds only its own tokens" {
    const gpa = std.testing.allocator;
    var scratch: Scratch = undefined;

    try scratch.init(gpa);
    defer scratch.deinit(gpa);

    var files = try fixtures_collected(gpa);
    defer files.deinit(gpa);

    var compared: u32 = 0;

    for (files.slice()) |*file| {
        if (try note_relation(gpa, &scratch, file)) compared += 1;
    }

    if (compared <= 90) {
        std.debug.print("too few fixtures carry a tag boundary: {d}\n", .{compared});
    }

    try std.testing.expect(compared > 90);
}
