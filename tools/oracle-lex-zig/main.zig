const std = @import("std");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
    const arguments = try std.process.argsAlloc(allocator);

    if (arguments.len != 2) {
        std.debug.print("usage: oracle-lex-zig <path>\n", .{});
        std.process.exit(2);
    }

    const source = try std.fs.cwd().readFileAllocOptions(
        allocator,
        arguments[1],
        1 << 24,
        null,
        @alignOf(u8),
        0,
    );

    const out = std.io.getStdOut().writer();
    var tokenizer = std.zig.Tokenizer.init(source);
    const bound = source.len + 1;
    var counted: usize = 0;

    while (counted < bound) : (counted += 1) {
        const token = tokenizer.next();

        if (token.tag == .eof) break;

        if (token.tag == .l_brace or token.tag == .r_brace) continue;

        const offset = token.loc.start;
        const length = token.loc.end - token.loc.start;

        try out.print("{d}:{d} {s}\n", .{ offset, length, class(token.tag) });
    }
}

fn class(tag: std.zig.Token.Tag) []const u8 {
    if (std.mem.startsWith(u8, @tagName(tag), "keyword_")) return "keyword";

    return switch (tag) {
        .identifier, .builtin => "identifier",
        .string_literal, .multiline_string_literal_line, .char_literal => "string",
        .number_literal => "number",
        .doc_comment, .container_doc_comment => "comment",
        else => if (tag.lexeme()) |text|
            (if (is_word(text)) "keyword" else "punctuation")
        else
            "punctuation",
    };
}

fn is_word(text: []const u8) bool {
    for (text) |byte| {
        if (!std.ascii.isAlphabetic(byte) and byte != '_') return false;
    }

    return text.len > 0;
}
