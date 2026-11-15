const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../../stdx/bounded/array.zig").ArrayType;
const EventsType = @import("../tree.zig").EventsType;
const Grammar = @import("dialect.zig").Grammar;
const Kind = @import("kind.zig").Kind;
const Parser = @import("parse.zig").Parser;
const Slash = @import("lex.zig").Slash;
const Structure = @import("../tree.zig").Structure;
const Tokens = @import("../tokens.zig");
const TreeType = @import("../tree.zig").TreeType;
const lex_slashed = @import("lex.zig").lex_slashed;
const raw_of = @import("../raw.zig").raw_of;
const slash_count_max = @import("lex.zig").slash_count_max;
const Events = EventsType(Kind);
const Tree = TreeType(Kind);

pub const Lexed = struct {
    raw: *ArrayType(Kind),
    tokens: *Tokens,
};

pub fn build(
    parser: *Parser,
    source: []const u8,
    lexed: Lexed,
    events: *Events,
    tree: *Tree,
    grammar: Grammar,
) error{Truncated}!Structure {
    var slashes: [slash_count_max]Slash = undefined;
    var slash_count: u32 = 0;

    assert(source.len <= std.math.maxInt(u32));
    assert(lexed.raw.capacity() >= lexed.tokens.items.capacity());

    for (0..slash_count_max + 1) |_| {
        lexed.tokens.clear();

        try lex_slashed(source, lexed.tokens, grammar.dialect, slashes[0..slash_count]);
        try raw_of(Kind, lexed.tokens.slice(), lexed.raw);

        const built = parser.build(
            source,
            lexed.tokens.slice(),
            lexed.raw.const_slice(),
            events,
            tree,
            grammar,
        );

        const slash = parser.slash orelse return built;

        if (built != .complete) return built;
        if (slash_count == slash_count_max) return built;
        if (slash_held(slashes[0..slash_count], slash.offset)) return built;

        slashes[slash_count] = slash;
        slash_count += 1;
    }

    unreachable;
}

fn slash_held(slashes: []const Slash, offset: u32) bool {
    assert(slashes.len <= slash_count_max);

    for (slashes) |slash| {
        if (slash.offset == offset) return true;
    }

    return false;
}
