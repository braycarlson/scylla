const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../../stdx/bounded/array.zig").ArrayType;
const Buffer = @import("../../stdx/bounded/buffer.zig");
const EventsType = @import("../../syntax/tree.zig").EventsType;
const Index = @import("../../text/line_index.zig").LineIndex;
const Kind = @import("../../syntax/python/kind.zig").Kind;
const Parser = @import("../../syntax/python/parse.zig").Parser;
const Structure = @import("../../syntax/tree.zig").Structure;
const Style = @import("../../syntax/python/style.zig").Style;
const Tokens = @import("../../syntax/tokens.zig");
const TreeType = @import("../../syntax/tree.zig").TreeType;
const raw_of = @import("../../syntax/raw.zig").raw_of;
const imports = @import("imports.zig");
const lex = @import("../../syntax/python/lex.zig").lex;
const style = @import("../../syntax/python/style.zig");
const Block = imports.Block;
const Events = EventsType(Kind);
const Parsed = imports.Parsed;
const Tree = TreeType(Kind);

const Fixture = struct {
    blocks: ArrayType(Block),
    events: Events,
    index: Index,
    out: Buffer,
    parser: Parser,
    raw: ArrayType(Kind),
    source: []const u8,
    style: Style,
    tokens: Tokens,
    tree: Tree,

    fn create(gpa: std.mem.Allocator, source: []const u8) !*Fixture {
        assert(source.len <= std.math.maxInt(u32));

        const fixture = try gpa.create(Fixture);
        errdefer gpa.destroy(fixture);

        fixture.blocks = try .init(gpa, block_count_max);
        errdefer fixture.blocks.deinit(gpa);

        try fixture.events.init(gpa, event_count_max);
        errdefer fixture.events.deinit(gpa);

        fixture.index = try .init(gpa, line_count_max);
        errdefer fixture.index.deinit(gpa);

        fixture.out = try .init(gpa, out_capacity_max);
        errdefer fixture.out.deinit(gpa);

        fixture.raw = try .init(gpa, token_count_max);
        errdefer fixture.raw.deinit(gpa);

        fixture.tokens = try .init(gpa, token_count_max);
        errdefer fixture.tokens.deinit(gpa);

        fixture.tree = try .init(gpa, node_count_max, diagnostic_count_max);
        errdefer fixture.tree.deinit(gpa);

        fixture.source = source;

        try fixture.build();

        return fixture;
    }

    fn destroy(fixture: *Fixture, gpa: std.mem.Allocator) void {
        fixture.tree.deinit(gpa);
        fixture.tokens.deinit(gpa);
        fixture.raw.deinit(gpa);
        fixture.out.deinit(gpa);
        fixture.index.deinit(gpa);
        fixture.events.deinit(gpa);
        fixture.blocks.deinit(gpa);
        gpa.destroy(fixture);
    }

    fn build(fixture: *Fixture) !void {
        try lex(fixture.source, &fixture.tokens);
        try raw_of(Kind, fixture.tokens.slice(), &fixture.raw);

        const structure = fixture.parser.build(
            fixture.source,
            fixture.tokens.slice(),
            fixture.raw.const_slice(),
            &fixture.events,
            &fixture.tree,
        );

        try std.testing.expectEqual(Structure.complete, structure);
        try fixture.index.build(fixture.source);
        try imports.blocks(fixture.tokens.slice(), &fixture.tree, &fixture.index, &fixture.blocks);

        fixture.style = style.detect(fixture.source, fixture.tokens.slice());
    }

    fn parsed(fixture: *const Fixture) Parsed {
        return .{
            .index = &fixture.index,
            .source = fixture.source,
            .tokens = fixture.tokens.slice(),
            .tree = &fixture.tree,
        };
    }

    fn sorted_into(
        fixture: *const Fixture,
        position: u32,
        modules_first_party: []const []const u8,
        out: *Buffer,
    ) ?[]const u8 {
        assert(position < fixture.blocks.count());
        assert(modules_first_party.len <= std.math.maxInt(u32));

        const block = fixture.blocks.get(position);
        const parsed_file = fixture.parsed();

        const sorted_block = imports.sort(
            &parsed_file,
            &block,
            modules_first_party,
            fixture.style,
            line_width,
            out,
        );

        sorted_block catch |err| switch (err) {
            error.Overflow, error.Refused => return null,
        };

        return out.const_slice();
    }

    fn sorted(fixture: *Fixture) ?[]const u8 {
        assert(fixture.blocks.count() == 1);

        return fixture.sorted_into(0, &.{}, &fixture.out);
    }
};

const block_count_max: u32 = 1 << 8;
const diagnostic_count_max: u32 = 1 << 8;
const event_count_max: u32 = 1 << 16;
const line_count_max: u32 = 1 << 12;
const line_width: u32 = 88;
const node_count_max: u32 = 1 << 14;
const out_capacity_max: u32 = 1 << 14;
const token_count_max: u32 = 1 << 14;

fn expect_sorted(source: []const u8, expected: []const u8) !void {
    assert(source.len <= std.math.maxInt(u32));

    const fixture = try Fixture.create(std.testing.allocator, source);
    defer fixture.destroy(std.testing.allocator);

    const held = fixture.sorted() orelse return error.TestUnexpectedResult;

    try std.testing.expectEqualStrings(expected, held);
}

fn expect_refused(source: []const u8) !void {
    assert(source.len <= std.math.maxInt(u32));

    const fixture = try Fixture.create(std.testing.allocator, source);
    defer fixture.destroy(std.testing.allocator);

    try std.testing.expect(fixture.sorted() == null);
}

fn expect_rendered(expected: []const u8, held: ?[]const u8) !void {
    if (held == null) return error.TestUnexpectedResult;

    const rendered = held.?;

    try std.testing.expectEqualStrings(expected, rendered);
}

test "a mixed block sorts into sections with a blank line between them" {
    try expect_sorted(
        "import requests\nimport os\nfrom collections import OrderedDict\nimport sys" ++
            "\nfrom mypkg import thing\n",
        "import os\nimport sys\nfrom collections import OrderedDict\n" ++
            "\nimport requests\nfrom mypkg import thing\n",
    );
}

test "a plain import of several modules splits into one statement each" {
    try expect_sorted(
        "import os, sys, collections\n",
        "import collections\nimport os\nimport sys\n",
    );
}

test "a from statement past the line width wraps one name a line" {
    try expect_sorted(
        "from collections import OrderedDict, defaultdict, namedtuple, Counter, deque, " ++
            "ChainMap, UserDict\n",
        "from collections import (\n" ++
            "    ChainMap,\n" ++
            "    Counter,\n" ++
            "    OrderedDict,\n" ++
            "    UserDict,\n" ++
            "    defaultdict,\n" ++
            "    deque,\n" ++
            "    namedtuple,\n" ++
            ")\n",
    );
}

test "a magic trailing comma keeps a short statement exploded" {
    try expect_sorted("from a import (\n    b,\n)\n", "from a import (\n    b,\n)\n");
}

test "a parenthesis closed without a comma collapses onto one line" {
    try expect_sorted("from a import (\n    c,\n    b\n)\n", "from a import b, c\n");
}

test "a magic trailing comma carries through a merge and stays off the alias" {
    try expect_sorted(
        "from a import x as y, b\nfrom a import (\n    z,\n)\n",
        "from a import (\n    b,\n    z,\n)\nfrom a import x as y\n",
    );
}

test "a magic trailing comma on a statement with an alias explodes both statements" {
    try expect_sorted(
        "from a import (B, a, c as d,)\n",
        "from a import (\n    B,\n    a,\n)\nfrom a import (\n    c as d,\n)\n",
    );
}

test "a wrapped statement indents with the file s own bytes" {
    try expect_sorted(
        "from a import (\n    c,\n    b,\n)\n\n\ndef f():\n  \treturn 1\n",
        "from a import (\n  \tb,\n  \tc,\n)\n",
    );
}

test "an aliased name keeps its own statement below the plain ones" {
    try expect_sorted(
        "from collections import OrderedDict as OD, defaultdict, Counter\n",
        "from collections import Counter, defaultdict\nfrom collections import OrderedDict as OD\n",
    );
}

test "an aliased module keeps its alias" {
    try expect_sorted(
        "import numpy as np\nimport os\nfrom collections import OrderedDict as OD\n",
        "import os\nfrom collections import OrderedDict as OD\n\nimport numpy as np\n",
    );
}

test "a deeper relative import stands above a shallower one" {
    try expect_sorted(
        "from . import a\nfrom .. import b\nfrom ...pkg import c\nfrom .mod import d\n",
        "from ...pkg import c\nfrom .. import b\nfrom . import a\nfrom .mod import d\n",
    );
}

test "a relative import sorts below every absolute one" {
    try expect_sorted(
        "from . import sibling\nfrom ..pkg import thing\nimport os\n",
        "import os\n\nfrom ..pkg import thing\nfrom . import sibling\n",
    );
}

test "a module name sorts without regard to case" {
    try expect_sorted(
        "import Zebra\nimport apple\nimport Beta\n",
        "import apple\nimport Beta\nimport Zebra\n",
    );
}

test "a module name differing only in case sorts uppercase first" {
    try expect_sorted("import ab\nimport AB\n", "import AB\nimport ab\n");
}

test "a module name holding a number sorts in natural order" {
    try expect_sorted("import a10\nimport a9\n", "import a9\nimport a10\n");
}

test "a digit run opening on a zero sorts digit by digit" {
    try expect_sorted(
        "import a10\nimport a9\nimport a1\nimport a010\nimport a01\nimport a001\nimport a0" ++
            "\nimport a00\n",
        "import a0\n" ++
            "import a00\n" ++
            "import a001\n" ++
            "import a01\n" ++
            "import a010\n" ++
            "import a1\n" ++
            "import a9\n" ++
            "import a10\n",
    );
}

test "an imported name sorts constants then classes then the rest" {
    try expect_sorted(
        "from m import A, A_B, CONST1, _X, X1, Ab1, a, _, __\n",
        "from m import _X, A_B, CONST1, X1, A, Ab1, _, __, a\n",
    );
}

test "an imported name list already in type order is left as it stands" {
    try expect_sorted(
        "from collections import ZEBRA, Apple, beta\n",
        "from collections import ZEBRA, Apple, beta\n",
    );
}

test "a repeated import is written once" {
    try expect_sorted("import os\nimport os\n", "import os\n");
}

test "two statements over one module merge into one" {
    try expect_sorted(
        "from collections import b\nfrom collections import a\n",
        "from collections import a, b\n",
    );
}

test "a plain import stands above a from over the same module" {
    try expect_sorted("from a import x\nimport a\n", "import a\nfrom a import x\n");
}

test "a first party module sorts below every third party one" {
    const fixture = try Fixture.create(std.testing.allocator, "import requests\nimport mypkg\n");
    defer fixture.destroy(std.testing.allocator);

    var out: Buffer = try .init(std.testing.allocator, 1 << 12);
    defer out.deinit(std.testing.allocator);

    const modules_first_party: []const []const u8 = &.{"mypkg"};

    try expect_rendered(
        "import requests\n\nimport mypkg\n",
        fixture.sorted_into(0, modules_first_party, &out),
    );
}

test "a future import sorts above every other section" {
    try expect_sorted(
        "import os\nfrom __future__ import annotations\n",
        "from __future__ import annotations\n\nimport os\n",
    );
}

test "a carriage return line feed file sorts with its own ending" {
    try expect_sorted("import sys\r\nimport os\r\n", "import os\r\nimport sys\r\n");
}

test "a block holding a comment is refused rather than guessed at" {
    try expect_refused("import os\n# a comment\nimport sys\n");
}

test "a block holding a star import is refused" {
    try expect_refused("from os import *\nimport sys\n");
}

test "a block whose first import follows a statement on its line is refused" {
    const fixture = try Fixture.create(std.testing.allocator, "x = 1; import sys\nimport os\n");
    defer fixture.destroy(std.testing.allocator);

    try std.testing.expectEqual(1, fixture.blocks.count());
    try std.testing.expect(fixture.sorted() == null);
}

test "a block whose last import precedes a statement on its line is refused" {
    const fixture = try Fixture.create(std.testing.allocator, "import sys\nimport os; x = 1\n");
    defer fixture.destroy(std.testing.allocator);

    try std.testing.expectEqual(1, fixture.blocks.count());
    try std.testing.expect(fixture.sorted() == null);
}

test "a block past the import count is refused" {
    const gpa = std.testing.allocator;
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(gpa);

    try source.appendSlice(gpa, "from m import ");

    for (0..imports.import_count_max + 1) |position| {
        if (position > 0) try source.appendSlice(gpa, ", ");

        try source.print(gpa, "n{d}", .{position});
    }

    try source.append(gpa, '\n');
    try expect_refused(source.items);
}

test "a buffer too small for the block is reported rather than cut" {
    const fixture = try Fixture.create(std.testing.allocator, "import sys\nimport os\n");
    defer fixture.destroy(std.testing.allocator);

    var out: Buffer = try .init(std.testing.allocator, 4);
    defer out.deinit(std.testing.allocator);

    try std.testing.expect(fixture.sorted_into(0, &.{}, &out) == null);
    try std.testing.expectEqual(0, out.count());
}

test "a file with no import at all reports no block" {
    const fixture = try Fixture.create(std.testing.allocator, "value = 1\n");
    defer fixture.destroy(std.testing.allocator);

    try std.testing.expectEqual(0, fixture.blocks.count());
}

test "two runs separated by a statement are two blocks each sorted alone" {
    const source = "import sys\nimport os\n\nvalue = 1\n\nimport b\nimport a\n";
    const fixture = try Fixture.create(std.testing.allocator, source);
    defer fixture.destroy(std.testing.allocator);

    var out: Buffer = try .init(std.testing.allocator, 1 << 12);
    defer out.deinit(std.testing.allocator);

    try std.testing.expectEqual(2, fixture.blocks.count());
    try expect_rendered("import os\nimport sys\n", fixture.sorted_into(0, &.{}, &out));
    try expect_rendered("import a\nimport b\n", fixture.sorted_into(1, &.{}, &out));
}
