const std = @import("std");
const assert = std.debug.assert;
const Brackets = @import("../syntax/brackets.zig").Brackets;
const Span = @import("../stdx/bounded/span.zig");
const Tokens = @import("../syntax/tokens.zig");
const javascript = @import("javascript.zig");
const lex = @import("../syntax/lex.zig").lex;

const Built = struct {
    outline: javascript.Outline,
    pairs: Brackets,
    source: []const u8,
    tokens: Tokens,

    fn init(built: *Built, source: []const u8) !void {
        assert(source.len <= std.math.maxInt(u32));

        const gpa = std.testing.allocator;

        built.source = source;
        built.tokens = try .init(gpa, token_count_max);
        errdefer built.tokens.deinit(gpa);

        try lex(.of(.javascript), source, &built.tokens);

        built.pairs = try .init(gpa, token_count_max);
        errdefer built.pairs.deinit(gpa);

        try built.pairs.build(source, built.tokens.slice());

        try built.outline.init(gpa, .{
            .row_count_max = row_count_max,
            .segment_count_max = segment_count_max,
            .token_count_max = token_count_max,
        });

        javascript.build(source, built.tokens.slice(), &built.pairs, &built.outline);

        assert(built.outline.braces.count() == built.tokens.count());
        assert(built.outline.scopes.count() >= 1);
    }

    fn deinit(built: *Built) void {
        const gpa = std.testing.allocator;

        assert(built.tokens.count() <= token_count_max);
        assert(built.pairs.count() == built.tokens.count());

        built.outline.deinit(gpa);
        built.pairs.deinit(gpa);
        built.tokens.deinit(gpa);
    }

    fn callee(built: *const Built, call: javascript.Call, buffer: []u8) []const u8 {
        assert(buffer.len > 0);
        assert(call.paren_open < call.paren_close);
        assert(call.callee_segment_count > 0);

        const segments = built.outline.segments_of(
            call.callee_segment_first,
            call.callee_segment_count,
        );

        return built.join(segments, buffer);
    }

    fn calls_contain(built: *const Built, name: []const u8) bool {
        assert(name.len > 0);
        assert(name.len < name_bytes_max);

        var buffer: [name_bytes_max]u8 = undefined;

        for (built.outline.calls.const_slice()) |call| {
            if (std.mem.eql(u8, built.callee(call, &buffer), name)) return true;
        }

        return false;
    }

    fn declaration_named(built: *const Built, name: []const u8) ?javascript.Declaration {
        assert(name.len > 0);

        for (built.outline.declarations.const_slice()) |declaration| {
            if (!std.mem.eql(u8, built.text(declaration.name), name)) continue;

            assert(declaration.scope_token_start < declaration.scope_token_end);

            return declaration;
        }

        return null;
    }

    fn declarations_expect(
        built: *const Built,
        kind: javascript.DeclarationKind,
        expected: []const []const u8,
    ) !void {
        assert(expected.len <= row_count_max);

        var matched: u32 = 0;

        for (built.outline.declarations.const_slice()) |declaration| {
            if (declaration.kind != kind) continue;

            try std.testing.expect(matched < expected.len);
            try std.testing.expectEqualStrings(expected[matched], built.text(declaration.name));

            matched += 1;
        }

        assert(matched <= built.outline.declarations.count());

        try std.testing.expectEqual(expected.len, matched);
    }

    fn declarations_hold(
        built: *const Built,
        kind: javascript.DeclarationKind,
        name: []const u8,
    ) bool {
        assert(name.len > 0);
        assert(built.outline.scopes.count() >= 1);

        for (built.outline.declarations.const_slice()) |declaration| {
            if (declaration.kind != kind) continue;
            if (std.mem.eql(u8, built.text(declaration.name), name)) return true;
        }

        return false;
    }

    fn fate_of(built: *const Built, call: javascript.Call) javascript.Fate {
        assert(call.paren_close < built.tokens.count());

        const statements = built.outline.statements.const_slice();
        const fate = javascript.chain_fate(&call, built.source, built.tokens.slice(), statements);

        if (fate.floating) assert(!fate.chained);

        return fate;
    }

    fn join(built: *const Built, segments: []const Span, buffer: []u8) []const u8 {
        assert(buffer.len > 0);
        assert(segments.len <= std.math.maxInt(u32));

        var length: usize = 0;

        for (segments, 0..) |segment, index| {
            if (index > 0) {
                buffer[length] = '.';
                length += 1;
            }

            const text_held = built.text(segment);

            @memcpy(buffer[length..][0..text_held.len], text_held);
            length += text_held.len;
        }

        assert(length <= buffer.len);

        return buffer[0..length];
    }

    fn text(built: *const Built, span: Span) []const u8 {
        assert(span.end() <= built.source.len);
        assert(built.tokens.count() > 0);

        return span.text(built.source);
    }

    fn token_text(built: *const Built, index: u32) []const u8 {
        assert(index < built.tokens.count());
        assert(built.outline.braces.count() == built.tokens.count());

        return built.tokens.slice()[index].text(built.source);
    }
};

const name_bytes_max = 256;
const row_count_max = 1 << 12;
const segment_count_max = 1 << 13;
const token_count_max = 1 << 14;

test "a brace after an equals is an object and a function body is a block" {
    var built: Built = undefined;

    try built.init("const state = { a: 1 };\nfunction run() { return 2; }\n");
    defer built.deinit();

    var objects: u32 = 0;
    var blocks: u32 = 0;

    for (0..built.tokens.count()) |index| {
        switch (built.outline.brace_kind(@intCast(index))) {
            .object => objects += 1,
            .block => blocks += 1,
            .none => {},
        }
    }

    try std.testing.expectEqual(1, objects);
    try std.testing.expectEqual(1, blocks);
}

test "a declaration records its kind and its name" {
    var built: Built = undefined;

    try built.init("var a = 1;\nlet b = 2;\nconst c = 3;\nfunction d() {}\nclass E {}\n");
    defer built.deinit();

    try built.declarations_expect(.@"var", &.{"a"});
    try built.declarations_expect(.let, &.{"b"});
    try built.declarations_expect(.@"const", &.{"c"});
    try built.declarations_expect(.function, &.{"d"});
    try built.declarations_expect(.class, &.{"E"});
}

test "several declarators on one keyword each bind" {
    var built: Built = undefined;

    try built.init("let a = 1, b = 2, c;\n");
    defer built.deinit();

    try built.declarations_expect(.let, &.{ "a", "b", "c" });
}

test "a function binds its parameters" {
    var built: Built = undefined;

    try built.init("function run(first, second) { return first; }\n");
    defer built.deinit();

    try built.declarations_expect(.parameter, &.{ "first", "second" });
}

test "an arrow binds its parameters in both forms" {
    var bare: Built = undefined;

    try bare.init("const f = value => value + 1;\n");
    defer bare.deinit();

    var parenthesized: Built = undefined;

    try parenthesized.init("const f = (a, b) => a + b;\n");
    defer parenthesized.deinit();

    try bare.declarations_expect(.parameter, &.{"value"});
    try parenthesized.declarations_expect(.parameter, &.{ "a", "b" });
}

test "a catch clause binds its parameter" {
    var built: Built = undefined;

    try built.init("try { run(); } catch (error) { report(error); }\n");
    defer built.deinit();

    try built.declarations_expect(.catch_parameter, &.{"error"});
}

test "a destructuring pattern binds its leaves" {
    var built: Built = undefined;

    try built.init("const { first, second: renamed } = source;\n");
    defer built.deinit();

    try std.testing.expect(built.declarations_hold(.@"const", "first"));
    try std.testing.expect(built.declarations_hold(.@"const", "renamed"));
    try std.testing.expect(!built.declarations_hold(.@"const", "second"));
}

test "a block scoped declaration names a narrower scope than a var" {
    var built: Built = undefined;

    try built.init(
        "function run() {\n    var wide = 1;\n    if (x) {\n        let narrow = 2;\n    }\n}\n",
    );

    defer built.deinit();

    const wide = built.declaration_named("wide") orelse return error.TestUnexpectedResult;
    const narrow = built.declaration_named("narrow") orelse return error.TestUnexpectedResult;
    const wide_width = wide.scope_token_end - wide.scope_token_start;
    const narrow_width = narrow.scope_token_end - narrow.scope_token_start;

    try std.testing.expect(narrow_width < wide_width);
}

test "an object literal records each member" {
    var built: Built = undefined;

    try built.init("const data = { count: 1, name, run() { return 1; }, ...rest };\n");
    defer built.deinit();

    try std.testing.expectEqual(1, built.outline.objects.count());

    const members = built.outline.members_of(built.outline.objects.get(0));

    try std.testing.expectEqual(4, members.len);
    try std.testing.expectEqualStrings("count", built.text(members[0].name));
    try std.testing.expect(!members[0].is_shorthand);
    try std.testing.expectEqualStrings("name", built.text(members[1].name));
    try std.testing.expect(members[1].is_shorthand);
    try std.testing.expectEqualStrings("run", built.text(members[2].name));
    try std.testing.expect(members[2].is_method);
    try std.testing.expect(members[3].is_spread);
}

test "an async member that awaits is marked" {
    var built: Built = undefined;

    try built.init(
        "const data = { async load() { await fetch(url); }, plain() { return 1; } };\n",
    );

    defer built.deinit();

    const members = built.outline.members_of(built.outline.objects.get(0));

    try std.testing.expectEqual(2, members.len);
    try std.testing.expect(members[0].is_async);
    try std.testing.expect(members[0].has_await);
    try std.testing.expect(!members[1].is_async);
    try std.testing.expect(!members[1].has_await);
}

test "an await inside a nested function does not mark the member" {
    var built: Built = undefined;

    try built.init("const data = { run() { return async () => { await go(); }; } };\n");
    defer built.deinit();

    const members = built.outline.members_of(built.outline.objects.get(0));

    try std.testing.expectEqual(1, members.len);
    try std.testing.expect(!members[0].has_await);
}

test "a call records its chain and a new records its keyword" {
    var built: Built = undefined;

    try built.init("Alpine.directive('x-thing', handler);\nnew ViewGlue(root);\n");
    defer built.deinit();

    try std.testing.expect(built.calls_contain("Alpine.directive"));
    try std.testing.expect(built.calls_contain("new.ViewGlue"));
}

test "a call names the scope that encloses it" {
    var built: Built = undefined;

    try built.init("function run() { inner(); }\n");
    defer built.deinit();

    var buffer: [name_bytes_max]u8 = undefined;
    var found: ?javascript.Call = null;

    for (built.outline.calls.const_slice()) |call| {
        if (std.mem.eql(u8, built.callee(call, &buffer), "inner")) {
            found = call;

            break;
        }
    }

    const call = found orelse return error.TestUnexpectedResult;
    const scopes = built.outline.scopes.const_slice();
    const expected = [_]javascript.ScopeKind{ .block, .function, .program };
    var kinds: [expected.len + 1]javascript.ScopeKind = undefined;
    var kind_count: u32 = 0;
    var index = call.scope;

    while (index) |held| {
        try std.testing.expect(kind_count < kinds.len);

        kinds[kind_count] = scopes[held].kind;
        kind_count += 1;
        index = scopes[held].parent;
    }

    try std.testing.expectEqualSlices(javascript.ScopeKind, &expected, kinds[0..kind_count]);
}

test "a reassigned binding is recorded and a member write is not" {
    var built: Built = undefined;

    try built.init("let a = 1;\na = 2;\na += 3;\na++;\nb.c = 4;\n");
    defer built.deinit();

    const assigned = built.outline.assigned.const_slice();

    try std.testing.expectEqual(4, assigned.len);

    for (assigned) |held| {
        try std.testing.expectEqualStrings("a", built.text(held.name));
    }
}

test "a statement splits at a semicolon and at a line break" {
    var built: Built = undefined;

    try built.init("run();\nother()\nthird();\n");
    defer built.deinit();

    try std.testing.expectEqual(3, built.outline.statements.count());
}

test "a floating call is separated from a chained one" {
    var built: Built = undefined;

    try built.init("fetch(url);\nfetch(other).then(read);\nconst held = fetch(third);\n");
    defer built.deinit();

    var buffer: [name_bytes_max]u8 = undefined;
    var bare: ?javascript.Fate = null;
    var chained: ?javascript.Fate = null;
    var held_count: u32 = 0;

    for (built.outline.calls.const_slice()) |call| {
        const fate = built.fate_of(call);
        const fetches = std.mem.eql(u8, built.callee(call, &buffer), "fetch");

        if (bare == null) {
            if (fetches) {
                if (!fate.chained) bare = fate;
            }
        }

        if (chained == null) {
            if (fate.chained) chained = fate;
        }

        if (fetches) {
            if (!fate.floating) held_count += 1;
        }
    }

    try std.testing.expect(bare != null);
    try std.testing.expect(bare.?.floating);
    try std.testing.expect(chained != null);
    try std.testing.expect(!chained.?.floating);
    try std.testing.expect(held_count >= 1);
}

test "a floating call is graded against the innermost statement" {
    var built: Built = undefined;

    try built.init(
        "{ items: [], init() { fetch(one); this.load(); }, " ++
            "load() { return fetch(two).then(read); } }\n" ++
            "function run() { const held = 1;\n fetch(three); }\n" ++
            "send(() => { fetch(four); });\nsend(fetch(five));\n",
    );

    defer built.deinit();

    const Expected = struct {
        floating: bool,
        name: []const u8,
    };

    const expected = [_]Expected{
        .{ .floating = false, .name = "init" },
        .{ .floating = true, .name = "fetch" },
        .{ .floating = true, .name = "this.load" },
        .{ .floating = false, .name = "load" },
        .{ .floating = false, .name = "fetch" },
        .{ .floating = false, .name = "then" },
        .{ .floating = false, .name = "run" },
        .{ .floating = true, .name = "fetch" },
        .{ .floating = true, .name = "send" },
        .{ .floating = true, .name = "fetch" },
        .{ .floating = true, .name = "send" },
        .{ .floating = false, .name = "fetch" },
    };

    var buffer: [name_bytes_max]u8 = undefined;
    const calls = built.outline.calls.const_slice();

    try std.testing.expectEqual(expected.len, calls.len);

    for (expected, calls) |want, call| {
        try std.testing.expectEqualStrings(want.name, built.callee(call, &buffer));
        try std.testing.expectEqual(want.floating, built.fate_of(call).floating);
    }
}

test "the x data reading walks the first object literal" {
    var built: Built = undefined;

    try built.init("{ open: false, toggle() { this.open = !this.open; } }");
    defer built.deinit();

    try std.testing.expect(!built.outline.objects.empty());

    const object = built.outline.objects.get(0);
    const members = built.outline.members_of(object);

    try std.testing.expectEqual(2, members.len);
    try std.testing.expectEqualStrings("open", built.text(members[0].name));
    try std.testing.expectEqualStrings("toggle", built.text(members[1].name));
    try std.testing.expectEqualStrings("{", built.token_text(object.brace_open));
    try std.testing.expectEqualStrings("}", built.token_text(object.brace_close));
}

test "an empty source records only the program scope" {
    var built: Built = undefined;

    try built.init("");
    defer built.deinit();

    try std.testing.expectEqual(1, built.outline.scopes.count());
    try std.testing.expectEqual(.program, built.outline.scopes.get(0).kind);
    try std.testing.expect(built.outline.calls.empty());
    try std.testing.expect(built.outline.declarations.empty());
}
