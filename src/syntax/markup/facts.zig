const std = @import("std");
const assert = std.debug.assert;
const FactKind = @import("../fact.zig").FactKind;
const Facts = @import("../fact.zig").Facts;
const Span = @import("../../stdx/bounded/span.zig");
const Token = @import("token.zig").Token;
const Tokens = @import("tokens.zig").Tokens;
const Tree = @import("tree.zig").Tree;
const View = @import("view.zig").View;
const lexer = @import("lex.zig");
const tree_module = @import("tree.zig");
const Structure = @import("../tree.zig").Structure;
const TemplateTag = View.TemplateTag;

pub const Words = struct {
    extends: []const []const u8,
    names: []const []const u8,
    only_word: ?[]const u8,
};

pub fn build(
    source: []const u8,
    tokens: []const Token,
    tree: *const Tree,
    facts: *Facts,
    words: *const Words,
) Structure {
    assert(source.len <= std.math.maxInt(u32));
    assert(tokens.len <= std.math.maxInt(u32));

    facts.clear();

    assert(facts.count() == 0);

    var outcome: Structure = .complete;
    var steps = tree_module.walk(tree);

    for (0..steps.step_max) |_| {
        const step = steps.next() orelse break;

        const node = switch (step) {
            .enter => |held| held,
            .leave => continue,
        };

        const view: View = .init(tree, tokens, @fromBackingInt(node));
        const tag = view.as_template_tag() orelse continue;
        if (!names_a_template(tag, source, words.names)) continue;

        const kind: FactKind = if (names_a_template(tag, source, words.extends))
            .extends
        else
            .{ .include = .{ .only = names_only(tag, source, words.only_word) } };

        facts.push(.{
            .binding = .none,
            .kind = kind,
            .local = view.span(),
            .remote = .empty,
            .specifier = specifier_of(tag, source) orelse .empty,
        }) catch |err| switch (err) {
            error.Truncated => outcome = .{ .truncated = .facts },
        };
    }

    assert(steps.node == null);
    assert(facts.count() <= tree.count());

    return outcome;
}

fn names_a_template(tag: TemplateTag, source: []const u8, names: []const []const u8) bool {
    assert(tag.view.kind() == .template_tag);
    assert(source.len <= std.math.maxInt(u32));
    assert(names.len <= std.math.maxInt(u32));

    const index = tag.name_token() orelse return false;
    const text = tag.view.token_at(index).text(source);

    for (names) |name| {
        if (std.mem.eql(u8, name, text)) return true;
    }

    return false;
}

fn names_only(tag: TemplateTag, source: []const u8, only_word: ?[]const u8) bool {
    assert(tag.view.kind() == .template_tag);
    assert(source.len <= std.math.maxInt(u32));
    if (only_word == null) return false;

    const word = only_word.?;

    assert(word.len > 0);

    var found = false;
    var pending = false;
    var arguments = tag.argument_tokens();

    for (0..tag.view.tokens.len) |_| {
        const index = arguments.next() orelse break;
        const token = tag.view.token_at(index);

        if (pending) {
            if (token.kind == .equals) {
                pending = false;

                continue;
            }
        }

        found = found or pending;
        pending = token.kind == .identifier and std.mem.eql(u8, token.text(source), word);
    }

    return found or pending;
}

fn specifier_of(tag: TemplateTag, source: []const u8) ?Span {
    assert(tag.view.kind() == .template_tag);
    assert(source.len <= std.math.maxInt(u32));

    var arguments = tag.argument_tokens();

    for (0..tag.view.tokens.len) |_| {
        const index = arguments.next() orelse break;
        const token = tag.view.token_at(index);
        if (token.kind != .string) continue;
        return token.unquote(source);
    }

    return null;
}

const extends_test = [_][]const u8{"extends"};
const only_test = "only";
const template_imports_test = [_][]const u8{ "extends", "include" };

const Built = struct {
    facts: Facts,
    outcome: Structure,
    tokens: Tokens,
    tree: Tree,

    fn init(built: *Built, gpa: std.mem.Allocator, source: []const u8) !void {
        assert(source.len <= std.math.maxInt(u32));

        built.tokens = try .init(gpa, 1 << 12);
        errdefer built.tokens.deinit(gpa);

        built.tree = try .init(gpa, 1 << 12, 1 << 6);
        errdefer built.tree.deinit(gpa);

        built.facts = try .init(gpa, 1 << 6);
        errdefer built.facts.deinit(gpa);

        try lexer.lex(source, &built.tokens);

        const structure = tree_module.build(source, built.tokens.slice(), &built.tree);

        try std.testing.expectEqual(Structure.complete, structure);

        const words: Words = .{
            .extends = &extends_test,
            .names = &template_imports_test,
            .only_word = only_test,
        };

        built.outcome = build(source, built.tokens.slice(), &built.tree, &built.facts, &words);
    }

    fn deinit(built: *Built, gpa: std.mem.Allocator) void {
        built.facts.deinit(gpa);
        built.tree.deinit(gpa);
        built.tokens.deinit(gpa);
        built.* = undefined;
    }
};

test "a literal extends spans its whole tag" {
    const gpa = std.testing.allocator;
    const source = "{% extends 'base.html' %}\n<p>hello</p>\n";
    var built: Built = undefined;

    try built.init(gpa, source);
    defer built.deinit(gpa);

    const fact = built.facts.slice()[0];

    try std.testing.expectEqual(Structure.complete, built.outcome);
    try std.testing.expectEqual(1, built.facts.count());
    try std.testing.expectEqual(FactKind.extends, fact.kind);
    try std.testing.expectEqualStrings("{% extends 'base.html' %}", fact.local.text(source));
    try std.testing.expectEqualStrings("base.html", fact.specifier.text(source));
}

test "an include spans its whole tag" {
    const gpa = std.testing.allocator;
    const source = "<div>{% include \"parts/card.html\" %}</div>\n";
    var built: Built = undefined;

    try built.init(gpa, source);
    defer built.deinit(gpa);

    const fact = built.facts.slice()[0];

    try std.testing.expectEqual(1, built.facts.count());
    try std.testing.expectEqual(FactKind{ .include = .{ .only = false } }, fact.kind);

    try std.testing.expectEqualStrings(
        "{% include \"parts/card.html\" %}",
        fact.local.text(source),
    );

    try std.testing.expectEqualStrings("parts/card.html", fact.specifier.text(source));
}

test "a dynamic target keeps its tag and names no specifier" {
    const gpa = std.testing.allocator;
    const source = "{% extends parent %}\n<p>hello</p>\n";
    var built: Built = undefined;

    try built.init(gpa, source);
    defer built.deinit(gpa);

    const fact = built.facts.slice()[0];

    try std.testing.expectEqual(1, built.facts.count());
    try std.testing.expectEqualStrings("{% extends parent %}", fact.local.text(source));
    try std.testing.expectEqual(Span.empty, fact.specifier);
}

test "an include with the only word says so" {
    const gpa = std.testing.allocator;
    const source = "{% include 'a.html' with x=1 only %}{% include 'b.html' with only=1 %}\n";
    var built: Built = undefined;

    try built.init(gpa, source);
    defer built.deinit(gpa);

    const held = built.facts.slice();

    try std.testing.expectEqual(2, held.len);
    try std.testing.expectEqual(FactKind{ .include = .{ .only = true } }, held[0].kind);
    try std.testing.expectEqual(FactKind{ .include = .{ .only = false } }, held[1].kind);
}

test "a tag that names no template is no fact" {
    const gpa = std.testing.allocator;
    const source = "{% block body %}{% endblock %}\n{% load static %}\n";
    var built: Built = undefined;

    try built.init(gpa, source);
    defer built.deinit(gpa);

    try std.testing.expectEqual(0, built.facts.count());
}
