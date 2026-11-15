const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../stdx/bounded/array.zig").ArrayType;
const SourceType = @import("language.zig").SourceType;
const Token = @import("token.zig");
const Tokens = @import("tokens.zig");
const lex = @import("lex.zig").lex;

pub fn raw_of(
    comptime Kind: type,
    tokens: []const Token,
    raw: *ArrayType(Kind),
) error{Truncated}!void {
    assert(tokens.len <= std.math.maxInt(u32));

    raw.clear();

    for (tokens) |token| {
        if (raw.full()) return error.Truncated;

        raw.push(token.exact_kind(Kind).?);
    }

    assert(raw.count() == tokens.len);
}

pub fn lex_into(
    comptime Kind: type,
    source_type: SourceType,
    source: []const u8,
    tokens: *Tokens,
    raw: *ArrayType(Kind),
) error{Truncated}!void {
    assert(source.len <= std.math.maxInt(u32));
    assert(source_type.valid());

    tokens.clear();

    try lex(source_type, source, tokens);
    try raw_of(Kind, tokens.slice(), raw);

    assert(raw.count() == tokens.count());
}
