const std = @import("std");
const assert = std.debug.assert;
const Emitter = @import("../python.zig").Emitter;
const Kind = @import("../python.zig").Kind;
const is_close = @import("../python.zig").is_close;
const is_layout = @import("../python.zig").is_layout;
const is_open = @import("../python.zig").is_open;

pub const Statement = packed struct(u8) {
    decorated: bool,
    ellipsis: bool,
    kind: StatementKind,
    padding: u1,
    spaced: bool,
    trailed: bool,

    pub const none: Statement = .{
        .decorated = false,
        .ellipsis = false,
        .kind = .none,
        .padding = 0,
        .spaced = false,
        .trailed = false,
    };

    fn defines(statement: Statement) bool {
        assert(statement.padding == 0);

        return statement.kind == .class or statement.kind == .function;
    }
};

pub const StatementKind = enum(u3) {
    class,
    decorator,
    function,
    none,
    other,
};

pub fn blanks(emitter: *const Emitter, position: u32, held: u32) ?u32 {
    assert(emitter.stub);
    assert(position < emitter.raw.len);
    assert(held <= 1);

    const level = emitter.indent;
    const above = comment_above(emitter, position);
    if (emitter.raw[position] == .comment) return commented(emitter, position, above, held);

    if (above) {
        if (held == 0) return null;
    }

    if (emitter.continues(position)) {
        if (above) return null;
        return alternated(emitter, level, held);
    }

    return bounded(emitter, level, following(emitter, position), false, held);
}

pub fn record(emitter: *Emitter, position: u32) void {
    assert(emitter.stub);
    assert(position < emitter.raw.len);

    const kind = emitter.raw[position];
    const level = emitter.indent;

    assert(level < emitter.statements.len);

    if (kind == .comment) return comments(emitter, position);
    if (emitter.continues(position)) return;

    const held = emitter.statements[level];
    const resolved = kind_of(emitter, position);

    if (held.kind == .decorator) {
        if (resolved == .decorator) return;

        const defining = resolved == .class or resolved == .function;

        if (defining) {
            emitter.statements[level].kind = resolved;

            return;
        }
    }

    emitter.statements[level] = .{
        .decorated = resolved == .decorator,
        .ellipsis = false,
        .kind = resolved,
        .padding = 0,
        .spaced = false,
        .trailed = false,
    };

    var scan = level + 1;

    while (scan < emitter.statements.len) : (scan += 1) {
        if (emitter.statements[scan].kind == .none) break;

        emitter.statements[scan] = .none;
    }

    assert(emitter.statements[level].kind != .none);
}

pub fn ellipsis(emitter: *Emitter, stubbed: bool) void {
    assert(emitter.stub);
    assert(emitter.indent < emitter.statements.len);

    const held = &emitter.statements[emitter.indent];
    if (!held.defines()) return;

    held.ellipsis = stubbed;

    assert(held.ellipsis == stubbed);
}

fn comments(emitter: *Emitter, position: u32) void {
    assert(emitter.raw[position] == .comment);
    assert(emitter.indent < emitter.statements.len);

    const held = &emitter.statements[emitter.indent];
    if (held.kind == .none) return;
    if (!trails(emitter, position)) return;

    if (!held.trailed) {
        held.spaced = emitter.blanks_before(position, emitter.tokens[position].offset) > 0;
    }

    held.trailed = true;
}

fn commented(emitter: *const Emitter, position: u32, above: bool, held: u32) ?u32 {
    assert(emitter.raw[position] == .comment);
    assert(held <= 1);

    const level = emitter.indent;

    if (trails(emitter, position)) {
        if (above) return null;
        return trailed(emitter, level, held);
    }

    if (above) {
        if (held == 0) return null;
    }

    const next = statement_after(emitter, position).?;
    const column = emitter.line_indent(emitter.tokens[position].offset);
    const column_next = emitter.line_indent(emitter.tokens[next].offset);

    assert(column_next >= column);

    if (column_next > column) return null;
    if (emitter.continues(next)) return alternated(emitter, level, held);
    return bounded(emitter, level, following(emitter, next), true, held);
}

fn alternated(emitter: *const Emitter, level: u32, held: u32) u32 {
    assert(level < emitter.statements.len);
    assert(held <= 1);

    if (chain_first_class(emitter, level)) return 1;
    return held;
}

fn trails(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.raw.len);
    assert(emitter.raw[position] == .comment);

    const next = statement_after(emitter, position) orelse return true;
    const column = emitter.line_indent(emitter.tokens[position].offset);
    const column_next = emitter.line_indent(emitter.tokens[next].offset);
    if (column_next < column) return true;
    if (column_next > column) return false;
    if (emitter.continues(next)) return false;

    const end = emitter.tokens[position].end();
    return empty_line_between(emitter.source, end, emitter.tokens[next].offset);
}

fn empty_line_between(source: []const u8, from: u32, to: u32) bool {
    assert(from <= to);
    assert(to <= source.len);

    var blank = false;

    for (source[from..to]) |byte| {
        switch (byte) {
            '\n' => {
                if (blank) return true;

                blank = true;
            },
            ' ', '\t', '\r', 0x0C => {},
            else => blank = false,
        }
    }

    return false;
}

fn trailed(emitter: *const Emitter, level: u32, held: u32) u32 {
    assert(level < emitter.statements.len);
    assert(held <= 1);

    return switch (emitter.statements[level].kind) {
        .class => 1,
        .function => if (level == 0) 1 else held,
        .decorator, .none, .other => held,
    };
}

fn bounded(
    emitter: *const Emitter,
    level: u32,
    next: Statement,
    leading: bool,
    held: u32,
) ?u32 {
    assert(level < emitter.statements.len);
    assert(held <= 1);
    assert(next.padding == 0);

    const preceding = emitter.statements[level];
    if (preceding.kind == .none) return null;

    if (!next.defines()) {
        if (!chain_defines(emitter, level)) return null;
    }

    const condition = leading or preceding.trailed or !omits_blank(preceding, next);
    const required = requires_blank(emitter, level, preceding, next);
    const spaced = if (preceding.trailed) preceding.spaced else held > 0;

    if (level == 0) return @intFromBool(condition or required);
    if (required) return 1;
    return @intFromBool(condition and spaced);
}

fn omits_blank(preceding: Statement, next: Statement) bool {
    assert(preceding.kind != .none);
    assert(next.kind != .none);

    if (!preceding.ellipsis) return false;

    if (preceding.kind == .class) {
        if (next.kind != .class) return false;
        if (next.decorated) return false;
        return next.ellipsis;
    }

    return preceding.kind == .function and next.kind == .function;
}

fn requires_blank(emitter: *const Emitter, level: u32, preceding: Statement, next: Statement) bool {
    assert(level < emitter.statements.len);
    assert(preceding.kind != .none);

    if (preceding.kind != .class) return chain_any_class(emitter, level);
    if (!preceding.ellipsis) return !preceding.trailed;
    if (preceding.decorated) return true;
    if (next.kind == .function) return true;
    if (next.kind != .class) return false;
    return !next.ellipsis or next.decorated;
}

fn chain_defines(emitter: *const Emitter, level: u32) bool {
    assert(level < emitter.statements.len);

    var scan = level;

    while (scan < emitter.statements.len) : (scan += 1) {
        const held = emitter.statements[scan];
        if (held.kind == .none) return false;
        if (held.trailed) return false;
        if (held.defines()) return true;
    }

    return false;
}

fn chain_any_class(emitter: *const Emitter, level: u32) bool {
    assert(level < emitter.statements.len);

    var scan = level + 1;

    while (scan < emitter.statements.len) : (scan += 1) {
        const held = emitter.statements[scan];
        if (held.kind == .none) return false;
        if (held.trailed) return false;
        if (held.kind == .class) return true;
    }

    return false;
}

fn chain_first_class(emitter: *const Emitter, level: u32) bool {
    assert(level < emitter.statements.len);

    var scan = level + 1;

    while (scan < emitter.statements.len) : (scan += 1) {
        const held = emitter.statements[scan];
        if (held.kind == .none) return false;
        if (held.trailed) return false;
        if (held.defines()) return held.kind == .class;
    }

    return false;
}

fn following(emitter: *const Emitter, position: u32) Statement {
    assert(position < emitter.raw.len);
    assert(emitter.raw[position] != .comment);

    const decorated = emitter.raw[position] == .at;
    const head = if (decorated) definition_after(emitter, position) else position;
    var held: Statement = .none;

    held.decorated = decorated;
    held.kind = if (head) |at| kind_of(emitter, at) else .other;

    if (!held.defines()) {
        held.kind = .other;

        return held;
    }

    const colon = header_colon(emitter, head.?) orelse return held;

    held.ellipsis = emitter.stubbed_at(colon) != null or emitter.stubs(colon);

    return held;
}

fn kind_of(emitter: *const Emitter, position: u32) StatementKind {
    assert(position < emitter.raw.len);
    assert(emitter.raw.len == emitter.tokens.len);

    return switch (emitter.raw[position]) {
        .at => .decorator,
        .class_keyword => .class,
        .def_keyword => .function,
        .async_keyword => if (emitter.opens_definition(position)) .function else .other,
        else => .other,
    };
}

fn definition_after(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.raw.len);
    assert(emitter.raw[position] == .at);

    const count: u32 = @intCast(emitter.raw.len);
    var depth: u32 = 0;
    var starts = false;
    var scan = position + 1;

    while (scan < count) : (scan += 1) {
        const kind = emitter.raw[scan];

        if (is_open(kind)) depth += 1;
        if (is_close(kind)) depth -|= 1;
        if (depth > 0) continue;

        if (kind == .newline) {
            starts = true;

            continue;
        }

        const skipped = is_layout(kind) or kind == .comment or emitter.tokens[scan].length == 0;
        if (skipped) continue;
        if (!starts) continue;

        if (kind == .at) {
            starts = false;

            continue;
        }

        const defined = kind == .class_keyword or kind == .def_keyword or kind == .async_keyword;
        return if (defined) scan else null;
    }

    return null;
}

fn header_colon(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.raw.len);
    assert(emitter.raw.len == emitter.tokens.len);

    const count: u32 = @intCast(emitter.raw.len);
    var depth: u32 = 0;
    var scan = position + 1;

    while (scan < count) : (scan += 1) {
        const kind = emitter.raw[scan];

        if (is_open(kind)) depth += 1;
        if (is_close(kind)) depth -|= 1;
        if (depth > 0) continue;

        if (kind == .colon) {
            assert(scan <= emitter.tokens.len);

            return scan;
        }

        if (kind == .newline) return null;
    }

    return null;
}

fn statement_after(emitter: *const Emitter, position: u32) ?u32 {
    assert(position < emitter.raw.len);
    assert(emitter.raw[position] == .comment);

    const count: u32 = @intCast(emitter.raw.len);
    var scan = position + 1;

    while (scan < count) : (scan += 1) {
        const kind = emitter.raw[scan];
        const skipped = is_layout(kind) or kind == .comment or emitter.tokens[scan].length == 0;

        if (!skipped) {
            assert(scan <= emitter.tokens.len);

            return scan;
        }
    }

    return null;
}

fn comment_above(emitter: *const Emitter, position: u32) bool {
    assert(position < emitter.raw.len);
    assert(emitter.raw.len == emitter.tokens.len);

    const column = emitter.line_indent(emitter.tokens[position].offset);
    var scan = position;

    while (scan > 0) {
        scan -= 1;

        const kind = emitter.raw[scan];
        const skipped = is_layout(kind) or emitter.tokens[scan].length == 0;
        if (skipped) continue;
        if (kind != .comment) return false;
        if (!emitter.heads_line(scan)) return false;
        return emitter.line_indent(emitter.tokens[scan].offset) == column;
    }

    return false;
}
