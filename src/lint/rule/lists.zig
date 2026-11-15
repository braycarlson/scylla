const std = @import("std");
const assert = std.debug.assert;
const Rule = @import("rule.zig");
const Selection = @import("selection.zig");

extend_select: []const []const u8,
ignore: []const []const u8,
ignore_extra: []const []const u8,
select: []const []const u8,

const Lists = @This();
pub const Preview = Selection.Preview;
pub const all = "ALL";

pub const Init = struct {
    extend_select: []const []const u8 = &.{},
    ignore: []const []const u8 = &.{},
    select: []const []const u8 = &.{},
};

pub fn init(given: Init) Lists {
    assert(given.select.len <= std.math.maxInt(u32));
    assert(given.ignore.len <= std.math.maxInt(u32));

    const selected: []const []const u8 = if (given.select.len == 0) &.{all} else given.select;

    assert(selected.len > 0);

    return .{
        .extend_select = given.extend_select,
        .ignore = given.ignore,
        .ignore_extra = &.{},
        .select = selected,
    };
}

pub fn any_matches(selectors: []const []const u8, code: []const u8) bool {
    assert(code.len > 0);
    assert(selectors.len <= std.math.maxInt(u32));

    for (selectors) |selector| {
        if (matches(selector, code)) return true;
    }

    return false;
}

pub fn is_enabled(lists: *const Lists, code: []const u8) bool {
    assert(code.len > 0);
    assert(lists.select.len > 0);

    var chosen = strongest(null, lists.select, code, null, .{});

    chosen = strongest(chosen, lists.extend_select, code, null, .{});

    return lists.enabled_at(chosen, code);
}

pub fn selects(lists: *const Lists, code: []const u8, group: Rule.Group, preview: Preview) bool {
    assert(code.len > 0);
    assert(lists.select.len > 0);

    var chosen = strongest(null, lists.select, code, group, preview);

    chosen = strongest(chosen, lists.extend_select, code, group, preview);

    return lists.enabled_at(chosen, code);
}

pub fn with_ignores(lists: *const Lists, extra: []const []const u8) Lists {
    assert(lists.ignore_extra.len == 0);
    assert(extra.len <= std.math.maxInt(u32));

    var widened = lists.*;

    widened.ignore_extra = extra;

    assert(widened.select.len == lists.select.len);

    return widened;
}

fn enabled_at(lists: *const Lists, chosen: ?u32, code: []const u8) bool {
    assert(code.len > 0);
    if (chosen) |held| assert(held <= code.len);

    const strength = chosen orelse return false;
    var ignored = strongest(null, lists.ignore, code, null, .{});

    ignored = strongest(ignored, lists.ignore_extra, code, null, .{});

    const weakest = ignored orelse return true;

    return strength > weakest;
}

fn matches(selector: []const u8, code: []const u8) bool {
    assert(code.len > 0);
    assert(selector.len <= std.math.maxInt(u32));

    return std.mem.startsWith(u8, code, prefix_of(selector));
}

fn prefix_of(selector: []const u8) []const u8 {
    assert(selector.len <= std.math.maxInt(u32));

    if (std.mem.eql(u8, selector, all)) return "";

    return selector;
}

fn strongest(
    current: ?u32,
    selectors: []const []const u8,
    code: []const u8,
    group: ?Rule.Group,
    preview: Preview,
) ?u32 {
    assert(code.len > 0);
    assert(selectors.len <= std.math.maxInt(u32));
    if (current) |held| assert(held <= code.len);

    var chosen = current;

    for (selectors) |selector| {
        const prefix = prefix_of(selector);
        if (!std.mem.startsWith(u8, code, prefix)) continue;

        if (group) |held| {
            if (!Selection.reachable(held, prefix.len == code.len, preview)) continue;
        }

        const strength: u32 = @intCast(prefix.len);

        if (chosen) |seen| {
            if (seen >= strength) continue;
        }

        chosen = strength;
    }

    if (current) |held| assert(chosen.? >= held);

    return chosen;
}

const running: Preview = .{ .enabled = true, .explicit = false };

test "an empty select enables every rule" {
    const lists: Lists = .init(.{});

    try std.testing.expect(lists.is_enabled("AL001"));
    try std.testing.expect(lists.is_enabled("GL016"));
    try std.testing.expect(lists.is_enabled("SY005"));
}

test "a select replaces the default set rather than adding to it" {
    const lists: Lists = .init(.{ .select = &.{ "GL", "SY" } });

    try std.testing.expect(lists.is_enabled("GL001"));
    try std.testing.expect(lists.is_enabled("SY001"));
    try std.testing.expect(!lists.is_enabled("HS001"));
    try std.testing.expect(!lists.is_enabled("AL001"));
}

test "extend select adds to the selected set" {
    const lists: Lists = .init(.{ .extend_select = &.{"HS008"}, .select = &.{"GL"} });

    try std.testing.expect(lists.is_enabled("GL001"));
    try std.testing.expect(lists.is_enabled("HS008"));
    try std.testing.expect(!lists.is_enabled("HS009"));
}

test "extend select on its own adds to every rule" {
    const lists: Lists = .init(.{ .extend_select = &.{"HS008"} });

    try std.testing.expect(lists.is_enabled("AL001"));
    try std.testing.expect(lists.is_enabled("HS008"));
}

test "ignore subtracts from the default set" {
    const lists: Lists = .init(.{ .ignore = &.{"HS010"} });

    try std.testing.expect(!lists.is_enabled("HS010"));
    try std.testing.expect(lists.is_enabled("HS011"));
    try std.testing.expect(lists.is_enabled("GL001"));
}

test "a pack prefix ignores the whole pack" {
    const lists: Lists = .init(.{ .ignore = &.{"HS"} });

    try std.testing.expect(!lists.is_enabled("HS001"));
    try std.testing.expect(!lists.is_enabled("HS015"));
    try std.testing.expect(lists.is_enabled("GL001"));
}

test "the longer selector wins whichever list it is in" {
    const selected_over_ignored: Lists = .init(.{ .ignore = &.{"GL"}, .select = &.{"GL001"} });

    try std.testing.expect(selected_over_ignored.is_enabled("GL001"));
    try std.testing.expect(!selected_over_ignored.is_enabled("GL002"));

    const ignored_over_selected: Lists = .init(.{ .ignore = &.{"GL001"}, .select = &.{"GL"} });

    try std.testing.expect(!ignored_over_selected.is_enabled("GL001"));
    try std.testing.expect(ignored_over_selected.is_enabled("GL002"));
}

test "ignore wins when two selectors are equally specific" {
    const lists: Lists = .init(.{ .ignore = &.{"GL001"}, .select = &.{"GL001"} });

    try std.testing.expect(!lists.is_enabled("GL001"));
}

test "all is the least specific selector" {
    const lists: Lists = .init(.{ .ignore = &.{"HS"}, .select = &.{all} });

    try std.testing.expect(lists.is_enabled("GL001"));
    try std.testing.expect(!lists.is_enabled("HS001"));

    const widened: Lists = .init(.{ .ignore = &.{all}, .select = &.{"HS"} });

    try std.testing.expect(widened.is_enabled("HS001"));
    try std.testing.expect(!widened.is_enabled("GL001"));
}

test "an intermediate prefix selects a run of codes" {
    const lists: Lists = .init(.{ .select = &.{"GL01"} });

    try std.testing.expect(lists.is_enabled("GL010"));
    try std.testing.expect(lists.is_enabled("GL016"));
    try std.testing.expect(!lists.is_enabled("GL009"));
}

test "extra ignores narrow a selection for one file" {
    const lists: Lists = .init(.{ .select = &.{"GL"} });
    const narrowed = lists.with_ignores(&.{"GL001"});

    try std.testing.expect(lists.is_enabled("GL001"));
    try std.testing.expect(!narrowed.is_enabled("GL001"));
    try std.testing.expect(narrowed.is_enabled("GL002"));
}

test "any matches reads all and prefixes" {
    try std.testing.expect(any_matches(&.{all}, "GL001"));
    try std.testing.expect(any_matches(&.{ "HS", "GL00" }, "GL001"));
    try std.testing.expect(!any_matches(&.{ "HS", "GL01" }, "GL001"));
    try std.testing.expect(!any_matches(&.{}, "GL001"));
}

test "a stable rule is reached by every selector" {
    try std.testing.expect(Lists.init(.{ .select = &.{all} }).selects("GL001", .stable, .{}));
    try std.testing.expect(Lists.init(.{ .select = &.{"GL"} }).selects("GL001", .stable, .{}));
    try std.testing.expect(Lists.init(.{ .select = &.{"GL001"} }).selects("GL001", .stable, .{}));
}

test "a preview rule needs the flag or its exact code" {
    const pack: Lists = .init(.{ .select = &.{"GL"} });
    const exact: Lists = .init(.{ .select = &.{"GL001"} });

    try std.testing.expect(!pack.selects("GL001", .preview, .{}));
    try std.testing.expect(exact.selects("GL001", .preview, .{}));
    try std.testing.expect(pack.selects("GL001", .preview, running));
}

test "explicit preview rules takes the prefix away" {
    const explicit: Preview = .{ .enabled = true, .explicit = true };
    const pack: Lists = .init(.{ .select = &.{"GL"} });
    const everything: Lists = .init(.{ .select = &.{all} });
    const exact: Lists = .init(.{ .select = &.{"GL001"} });

    try std.testing.expect(!pack.selects("GL001", .preview, explicit));
    try std.testing.expect(!everything.selects("GL001", .preview, explicit));
    try std.testing.expect(exact.selects("GL001", .preview, explicit));
}

test "a deprecated rule is reached only by its exact code outside preview" {
    const exact: Lists = .init(.{ .select = &.{"GL001"} });

    try std.testing.expect(!Lists.init(.{ .select = &.{all} }).selects("GL001", .deprecated, .{}));
    try std.testing.expect(!Lists.init(.{ .select = &.{"GL"} }).selects("GL001", .deprecated, .{}));
    try std.testing.expect(exact.selects("GL001", .deprecated, .{}));
    try std.testing.expect(!exact.selects("GL001", .deprecated, running));
}

test "a removed rule is reached only by its exact code" {
    try std.testing.expect(!Lists.init(.{ .select = &.{all} }).selects("GL001", .removed, .{}));
    try std.testing.expect(Lists.init(.{ .select = &.{"GL001"} }).selects("GL001", .removed, .{}));
}

test "an ignore wins at the same specificity and loses below it" {
    const tied: Lists = .init(.{ .ignore = &.{"GL001"}, .select = &.{"GL001"} });
    const broader: Lists = .init(.{ .ignore = &.{"GL"}, .select = &.{"GL001"} });

    try std.testing.expect(!tied.selects("GL001", .stable, .{}));
    try std.testing.expect(broader.selects("GL001", .stable, .{}));
}

test "a prefix that only reaches a preview rule exactly still counts as a prefix" {
    const lists: Lists = .init(.{
        .extend_select = &.{"GL001"},
        .ignore = &.{"GL"},
        .select = &.{"GL"},
    });

    try std.testing.expect(lists.selects("GL001", .preview, .{}));
    try std.testing.expect(!lists.selects("GL002", .stable, .{}));
}
