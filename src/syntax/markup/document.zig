const std = @import("std");
const assert = std.debug.assert;
const Kind = @import("kind.zig").Kind;
const Structure = @import("../tree.zig").Structure;
const Token = @import("token.zig").Token;
const View = @import("view.zig").View;
const Vocabulary = @import("vocabulary.zig").Vocabulary;
const blocks_module = @import("blocks.zig");
const diagnostic_module = @import("diagnostic.zig");
const lexer = @import("lex.zig");
const tokens_module = @import("tokens.zig");
const tree_module = @import("tree.zig");

pub const Document = struct {
    built: Tree,
    lexed: Tokens,
    paired: Blocks,

    pub const Blocks = blocks_module.Blocks;
    pub const Diagnostic = diagnostic_module.Diagnostic;
    pub const Error = CapacityError;
    pub const Node = enum(u32) { _ };
    pub const Tokens = tokens_module.Tokens;
    pub const Tree = tree_module.Tree;

    pub const Capacity = struct {
        diagnostic_count_max: u32,
        node_count_max: u32,
        tag_count_max: u32,
        token_count_max: u32,
    };

    pub const CapacityError = error{
        BlockDepthExceeded,
        DepthExceeded,
        DiagnosticsExhausted,
        IntermediatesExhausted,
        NodesExhausted,
        TagsExhausted,
        TokensExhausted,
    };

    pub fn init(gpa: std.mem.Allocator, capacity: Capacity) std.mem.Allocator.Error!Document {
        assert(capacity.diagnostic_count_max > 0);
        assert(capacity.node_count_max > 0);
        assert(capacity.tag_count_max > 0);
        assert(capacity.token_count_max > 0);

        var lexed: Tokens = try .init(gpa, capacity.token_count_max);
        errdefer lexed.deinit(gpa);

        var built: Tree = try .init(gpa, capacity.node_count_max, capacity.diagnostic_count_max);
        errdefer built.deinit(gpa);

        const paired: Blocks = try .init(gpa, capacity.tag_count_max);

        assert(lexed.capacity() == capacity.token_count_max);
        assert(built.count() == 0);

        return .{ .built = built, .lexed = lexed, .paired = paired };
    }

    pub fn deinit(document: *Document, gpa: std.mem.Allocator) void {
        assert(document.lexed.count() <= document.lexed.capacity());
        assert(document.built.count() <= document.built.nodes.capacity());

        document.paired.deinit(gpa);
        document.built.deinit(gpa);
        document.lexed.deinit(gpa);
        document.* = undefined;
    }

    pub fn at(document: *const Document, index: u32) View {
        assert(index < document.built.count());
        assert(document.lexed.count() <= document.lexed.capacity());

        return .init(&document.built, document.lexed.slice(), @fromBackingInt(index));
    }

    pub fn blocks(document: *const Document) *const Blocks {
        assert(document.paired.tag_slice().len <= document.built.count());
        assert(document.paired.block_slice().len <= document.paired.tag_slice().len);

        return &document.paired;
    }

    pub fn clear(document: *Document) void {
        document.lexed.clear();
        document.built.clear();
        document.paired.clear();

        assert(document.lexed.count() == 0);
        assert(document.built.count() == 0);
    }

    pub fn diagnostics(document: *const Document) []const Diagnostic {
        const found = document.built.diagnostic_slice();

        assert(found.len <= document.built.diagnostics.capacity());
        if (found.len > 0) assert(document.built.count() > 0);

        return found;
    }

    pub fn dump(
        document: *const Document,
        out: *std.Io.Writer,
        source: []const u8,
    ) std.Io.Writer.Error!void {
        assert(document.built.count() > 0);
        assert(document.lexed.end_previous == source.len);

        const stream = document.lexed.slice();

        try tree_module.dump_named(out, &document.built, stream, source, Kind.title);
    }

    pub fn node_count(document: *const Document) u32 {
        const held = document.built.count();

        assert(held <= document.built.nodes.capacity());
        if (held == 0) assert(document.lexed.count() == 0);

        return held;
    }

    pub fn parse(
        document: *Document,
        source: []const u8,
        vocabulary: *const Vocabulary,
    ) Error!void {
        assert(source.len <= std.math.maxInt(u32));
        assert(document.lexed.capacity() > 0);

        const dialect = vocabulary.dialect;
        const lexed = &document.lexed;
        const nodes = &document.built;
        const lexing = lexer.lex_dialect(source, lexed, vocabulary.raw_text_tags, dialect);
        const stream = lexed.slice();
        const building = tree_module.build_dialect(source, stream, nodes, dialect);
        const pairing = document.paired_build(source, vocabulary);

        assert(lexed.end_previous == source.len);
        assert(nodes.count() > 0);

        lexing catch |err| switch (err) {
            error.Truncated => return error.TokensExhausted,
        };

        try structure_checked(building);
        try pairing_checked(pairing);
    }

    fn paired_build(
        document: *Document,
        source: []const u8,
        vocabulary: *const Vocabulary,
    ) Structure {
        assert(source.len <= std.math.maxInt(u32));

        const stream = document.lexed.slice();

        if (!vocabulary.pairs()) {
            document.paired.clear();

            assert(document.paired.tag_slice().len == 0);

            return .complete;
        }

        return blocks_module.build(&document.paired, source, stream, &document.built, vocabulary);
    }

    pub fn root(document: *const Document) View {
        assert(document.built.count() > 0);
        assert(document.built.kind_at(0) == .document);

        return document.at(0);
    }

    pub fn source_length(document: *const Document) u32 {
        const held = document.lexed.end_previous;

        assert(document.lexed.count() <= held);
        if (document.lexed.count() == 0) assert(held == 0);

        return held;
    }

    pub fn tokens(document: *const Document) []const Token {
        const held = document.lexed.slice();

        assert(held.len <= document.lexed.capacity());
        if (held.len > 0) assert(held[0].offset == 0);

        return held;
    }

    pub fn tree(document: *const Document) *const Tree {
        assert(document.built.count() <= document.built.nodes.capacity());
        assert(document.built.diagnostic_slice().len <= document.built.diagnostics.capacity());

        return &document.built;
    }

    pub fn view(document: *const Document, node: Node) View {
        assert(@backingInt(node) < document.built.count());
        assert(document.lexed.count() <= document.lexed.capacity());

        return .init(&document.built, document.lexed.slice(), node);
    }

    fn pairing_checked(outcome: Structure) CapacityError!void {
        if (outcome == .too_deep) return error.BlockDepthExceeded;

        return structure_checked(outcome);
    }

    fn structure_checked(outcome: Structure) CapacityError!void {
        if (outcome == .too_deep) return error.DepthExceeded;

        switch (outcome) {
            .complete => {},
            .too_deep => unreachable,
            .truncated => |resource| switch (resource) {
                .diagnostics => return error.DiagnosticsExhausted,
                .intermediates => return error.IntermediatesExhausted,
                .nodes => return error.NodesExhausted,
                .tags => return error.TagsExhausted,
                .tokens => return error.TokensExhausted,
                .bindings, .checks, .events, .facts, .lines, .references, .scopes => unreachable,
            },
        }
    }
};

const capacity_test: Document.Capacity = .{
    .diagnostic_count_max = 1 << 4,
    .node_count_max = 1 << 8,
    .tag_count_max = 1 << 4,
    .token_count_max = 1 << 8,
};

test Document {
    const gpa = std.testing.allocator;
    const source = "{% if user %}<p>{{ user.name }}</p>{% endif %}<div>";
    var document: Document = try .init(gpa, capacity_test);
    defer document.deinit(gpa);

    var vocabulary: Vocabulary = .empty;

    vocabulary.end_prefix = "end";

    try document.parse(source, &vocabulary);

    const diagnostic = document.diagnostics()[0];

    try std.testing.expectEqual(Document.Diagnostic.Kind.unclosed_element, diagnostic.kind);
    try std.testing.expectEqualStrings("div", diagnostic.name.text(source));
    try std.testing.expect(document.blocks().block_slice()[0].is_closed());
    try std.testing.expectEqual(Kind.document, document.root().kind());
    try std.testing.expectEqual(source.len, document.source_length());
}

test "a parse past its token table keeps what it built" {
    const gpa = std.testing.allocator;
    var capacity = capacity_test;

    capacity.token_count_max = 4;

    var document: Document = try .init(gpa, capacity);
    defer document.deinit(gpa);

    const source = "<p>a</p><p>b</p>";

    try std.testing.expectError(error.TokensExhausted, document.parse(source, &.empty));
    try std.testing.expectEqual(4, document.tokens().len);
    try std.testing.expectEqual(source.len, document.source_length());
    try std.testing.expect(document.node_count() > 0);

    document.clear();

    try std.testing.expectEqual(0, document.node_count());
    try document.parse("plain", &.empty);
    try std.testing.expectEqual(1, document.tokens().len);
    try std.testing.expectEqual(0, document.diagnostics().len);
}

test "a dump names each kind in title case" {
    const gpa = std.testing.allocator;
    const source = "<p>a</p>";
    var document: Document = try .init(gpa, capacity_test);
    defer document.deinit(gpa);

    try document.parse(source, &.empty);

    var buffer: [1 << 10]u8 = undefined;
    var out: std.Io.Writer = .fixed(&buffer);

    try document.dump(&out, source);

    const written = out.buffered();

    try std.testing.expect(std.mem.startsWith(u8, written, "Document@0..8\n  Element@0..8"));
    try std.testing.expect(std.mem.find(u8, written, "ElementName@1..2 \"p\"") != null);
}
