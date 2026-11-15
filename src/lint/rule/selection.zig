const std = @import("std");
const assert = std.debug.assert;
const bounded = @import("../../stdx/bounded.zig");
const CodeSet = @import("code_set.zig");
const Registry = @import("registry.zig");
const Rule = @import("rule.zig");
const json = @import("json");
const code_text_bytes_max = Rule.code_text_bytes_max;
const rule_count_max = CodeSet.rule_count_max;

extend_fixable: Selectors,
extend_select: Selectors,
external: Selectors,
fixable: Selectors,
fixable_replaced: bool,
ignore: Selectors,
preview: Preview,
select: Selectors,
selected: bool,
unfixable: Selectors,

const Selection = @This();
pub const CapacityError = error{SelectorsExhausted};

pub const Faults = struct {
    selector_count: u32,
    value_count: u32,
};

pub const List = enum {
    extend_fixable,
    extend_select,
    external,
    fixable,
    ignore,
    select,
    unfixable,
};

pub const Preview = struct {
    enabled: bool = false,
    explicit: bool = false,
};

pub const Replaceable = enum {
    fixable,
    select,
};

pub const Selector = struct {
    length: u8,
    text: [code_text_bytes_max]u8,

    const all: Selector = .{ .length = 0, .text = @splat(0) };

    pub fn named(registry: *const Registry, text: []const u8) ?Selector {
        assert(registry.count() <= rule_count_max);

        if (text.len == 0) return null;
        if (std.mem.eql(u8, text, all_text)) return all;

        if (Selector.of(text)) |selector| {
            for (registry.slice()) |*item| {
                if (selector.matches(item.code)) return selector;
            }
        }

        const held = registry.find_name(text) orelse return null;

        assert(held.code.len <= code_text_bytes_max);

        return Selector.of(held.code);
    }

    fn of(text: []const u8) ?Selector {
        assert(text.len <= std.math.maxInt(u32));

        if (std.mem.eql(u8, text, all_text)) return all;
        if (text.len == 0) return null;
        if (text.len > code_text_bytes_max) return null;

        var held: Selector = .{ .length = @intCast(text.len), .text = @splat(0) };

        @memcpy(held.text[0..text.len], text);

        assert(held.length > 0);
        assert(std.mem.eql(u8, held.bytes(), text));

        return held;
    }

    fn bytes(selector: *const Selector) []const u8 {
        assert(selector.length <= code_text_bytes_max);

        return selector.text[0..selector.length];
    }

    fn is_all(selector: *const Selector) bool {
        assert(selector.length <= code_text_bytes_max);

        return selector.length == 0;
    }

    fn is_exact(selector: *const Selector, code: []const u8) bool {
        assert(selector.length <= code_text_bytes_max);
        assert(code.len <= std.math.maxInt(u32));

        return std.mem.eql(u8, selector.bytes(), code);
    }

    pub fn matches(selector: *const Selector, code: []const u8) bool {
        assert(selector.length <= code_text_bytes_max);
        assert(code.len <= std.math.maxInt(u32));

        return std.mem.startsWith(u8, code, selector.bytes());
    }

    fn specificity(selector: *const Selector) u8 {
        assert(selector.length <= code_text_bytes_max);

        return selector.length;
    }
};

const Selectors = bounded.ArrayType(Selector);
const all_text = "ALL";

const selection_lists = [_][]const u8{
    "extend_fixable",
    "extend_select",
    "external",
    "fixable",
    "ignore",
    "select",
    "unfixable",
};

comptime {
    assert(selection_lists.len == @typeInfo(List).@"enum".field_names.len);
}

pub fn init(gpa: std.mem.Allocator, selector_count_max: u32) std.mem.Allocator.Error!Selection {
    assert(selector_count_max > 0);

    var selection: Selection = undefined;

    selection.fixable_replaced = false;
    selection.preview = .{};
    selection.selected = false;

    var initialised: u32 = 0;
    errdefer selection_lists_free(&selection, gpa, initialised);

    inline for (selection_lists) |field| {
        @field(selection, field) = try Selectors.init(gpa, selector_count_max);
        initialised += 1;
    }

    assert(initialised == selection_lists.len);

    return selection;
}

pub fn deinit(selection: *Selection, gpa: std.mem.Allocator) void {
    assert(selection.count() <= selection_lists.len * selection.select.capacity());

    selection_lists_free(selection, gpa, selection_lists.len);
    selection.* = undefined;
}

pub fn clear(selection: *Selection) void {
    inline for (selection_lists) |field| @field(selection, field).clear();

    selection.fixable_replaced = false;
    selection.preview = .{};
    selection.selected = false;

    assert(selection.count() == 0);
}

pub fn count_of(selection: *const Selection, list: List) u32 {
    const held = switch (list) {
        inline else => |tag| @field(selection, @tagName(tag)).count(),
    };

    assert(held <= selection.select.capacity());
    assert(held <= selection.count());

    return held;
}

pub fn is_selected(selection: *const Selection) bool {
    if (!selection.selected) assert(selection.select.empty());

    return selection.selected;
}

fn is_external(selection: *const Selection, code: []const u8) bool {
    if (code.len == 0) return false;

    for (selection.external.const_slice()) |*prefix| {
        if (prefix.is_all()) continue;
        if (std.mem.startsWith(u8, code, prefix.bytes())) return true;
    }

    return false;
}

pub fn overlay(selection: *Selection, over: *const Selection) u32 {
    var dropped: u32 = 0;

    if (over.selected) {
        selection.replace(.select);
        dropped += pushed_from(&selection.select, over.select.const_slice());
    }

    if (over.fixable_replaced) {
        selection.replace(.fixable);
        dropped += pushed_from(&selection.fixable, over.fixable.const_slice());
    }

    dropped += pushed_from(&selection.extend_select, over.extend_select.const_slice());
    dropped += pushed_from(&selection.ignore, over.ignore.const_slice());
    dropped += pushed_from(&selection.extend_fixable, over.extend_fixable.const_slice());
    dropped += pushed_from(&selection.unfixable, over.unfixable.const_slice());
    dropped += pushed_from(&selection.external, over.external.const_slice());

    assert(dropped <= over.count());
    assert(selection.count() <= selection_lists.len * selection.select.capacity());

    return dropped;
}

pub fn preview_set(selection: *Selection, preview: Preview) void {
    selection.preview = preview;

    assert(selection.preview.enabled == preview.enabled);
    assert(selection.preview.explicit == preview.explicit);
}

pub fn push(selection: *Selection, list: List, selector: Selector) CapacityError!void {
    assert(selector.length <= code_text_bytes_max);

    const target = switch (list) {
        inline else => |tag| &@field(selection, @tagName(tag)),
    };

    if (target.full()) return error.SelectorsExhausted;

    target.push(selector);

    assert(!target.empty());
    assert(target.count() <= target.capacity());
}

pub fn replace(selection: *Selection, list: Replaceable) void {
    switch (list) {
        .fixable => {
            selection.fixable.clear();
            selection.extend_fixable.clear();
            selection.unfixable.clear();
            selection.fixable_replaced = true;
        },
        .select => {
            selection.select.clear();
            selection.extend_select.clear();
            selection.ignore.clear();
            selection.selected = true;
        },
    }

    assert(selection.count() <= selection_lists.len * selection.select.capacity());
}

pub fn resolve(selection: *const Selection, rules: *const Registry) CodeSet {
    var enabled = CodeSet.empty;

    assert(rules.count() <= rule_count_max);

    for (rules.slice(), 0..) |*item, rule_index| {
        const exact = selection_exact(selection, item.code);
        if (!reachable(item.group, exact, selection.preview)) continue;
        if (!selection.covers(item.default_on, item.code)) continue;

        enabled.insert(@intCast(rule_index));
    }

    selection_resolved_check(enabled, rules);
    assert(enabled.count() <= rules.count());

    return enabled;
}

pub fn resolve_fixable(selection: *const Selection, rules: *const Registry) CodeSet {
    var allowed = CodeSet.empty;

    assert(rules.count() <= rule_count_max);

    for (rules.slice(), 0..) |*item, rule_index| {
        if (!selection.fixes(item.code)) continue;

        allowed.insert(@intCast(rule_index));
    }

    selection_resolved_check(allowed, rules);
    assert(allowed.count() <= rules.count());

    return allowed;
}

pub fn resolve_language(
    selection: *const Selection,
    over: *const Selection,
    rules: *const Registry,
) CodeSet {
    var enabled = CodeSet.empty;

    assert(rules.count() <= rule_count_max);

    for (rules.slice(), 0..) |*item, rule_index| {
        const exact_base = selection_exact(selection, item.code);
        const exact_over = selection_exact(over, item.code);
        const exact = exact_base or exact_over;
        if (!reachable(item.group, exact, selection.preview)) continue;
        if (!selection.covers_with(over, item.default_on, item.code)) continue;

        enabled.insert(@intCast(rule_index));
    }

    selection_resolved_check(enabled, rules);
    assert(enabled.count() <= rules.count());

    return enabled;
}

pub fn selectors_read(
    selection: *Selection,
    registry: *const Registry,
    document: *const json.Document,
    listed: json.Node,
    list: List,
) Faults {
    assert(@backingInt(listed) < document.node_count);

    var faults: Faults = .{ .selector_count = 0, .value_count = 0 };

    assert(registry.count() <= rule_count_max);

    if (document.kind_of(listed) != .array) {
        faults.value_count += 1;

        return faults;
    }

    var names = document.items(listed);
    const element_count_max = names.remaining;

    for (0..element_count_max) |_| {
        const name = names.next() orelse break;

        const text = document.text_of(name) orelse {
            faults.value_count += 1;

            return faults;
        };

        const parsed = Selector.named(registry, text) orelse {
            faults.selector_count += 1;

            continue;
        };

        selection.push(list, parsed) catch |err| switch (err) {
            error.SelectorsExhausted => faults.value_count += 1,
        };
    }

    assert(faults.selector_count + faults.value_count <= element_count_max);

    return faults;
}

fn count(selection: *const Selection) u32 {
    var total: u32 = 0;

    inline for (selection_lists) |field| total += @field(selection, field).count();

    assert(total <= selection_lists.len * selection.select.capacity());

    return total;
}

fn selection_exact(selection: *const Selection, code: []const u8) bool {
    assert(code.len > 0);

    if (exact_in(selection.select.const_slice(), code)) return true;
    return exact_in(selection.extend_select.const_slice(), code);
}

fn covers_with(
    selection: *const Selection,
    over: *const Selection,
    default_on: bool,
    code: []const u8,
) bool {
    const replaced = over.selected;
    var chosen: ?u8 = null;

    assert(code.len > 0);

    if (!replaced) chosen = strength_default(selection.selected, default_on);

    if (replaced) {
        chosen = strongest(chosen, over.select.const_slice(), code);
    } else {
        chosen = strongest(chosen, selection.select.const_slice(), code);
        chosen = strongest(chosen, selection.extend_select.const_slice(), code);
    }

    chosen = strongest(chosen, over.extend_select.const_slice(), code);

    const strength = chosen orelse return false;
    var inherited: ?u8 = null;

    if (!replaced) inherited = strongest(null, selection.ignore.const_slice(), code);

    const ignored = strongest(inherited, over.ignore.const_slice(), code) orelse return true;
    return strength > ignored;
}

fn fixes(selection: *const Selection, code: []const u8) bool {
    var chosen: ?u8 = if (selection.fixable_replaced) null else 0;

    assert(code.len > 0);

    chosen = strongest(chosen, selection.fixable.const_slice(), code);
    chosen = strongest(chosen, selection.extend_fixable.const_slice(), code);

    const strength = chosen orelse return false;
    const refused = strongest(null, selection.unfixable.const_slice(), code) orelse return true;

    return strength > refused;
}

fn covers(selection: *const Selection, default_on: bool, code: []const u8) bool {
    var chosen = strength_default(selection.selected, default_on);

    assert(code.len > 0);

    chosen = strongest(chosen, selection.select.const_slice(), code);
    chosen = strongest(chosen, selection.extend_select.const_slice(), code);

    const strength = chosen orelse return false;
    const ignored = strongest(null, selection.ignore.const_slice(), code) orelse return true;

    return strength > ignored;
}

fn selection_lists_free(selection: *Selection, gpa: std.mem.Allocator, initialised: u32) void {
    assert(initialised <= selection_lists.len);

    inline for (selection_lists, 0..) |field, field_index| {
        if (field_index < initialised) @field(selection, field).deinit(gpa);
    }
}

pub fn reachable(group: Rule.Group, exact: bool, preview: Preview) bool {
    if (group == .stable) return true;

    return switch (group) {
        .deprecated => !preview.enabled and exact,
        .preview => exact or (preview.enabled and !preview.explicit),
        .removed => exact,
        .stable => true,
    };
}

fn exact_in(selectors: []const Selector, code: []const u8) bool {
    assert(code.len > 0);
    assert(selectors.len <= std.math.maxInt(u32));

    for (selectors) |*selector| {
        if (selector.is_exact(code)) return true;
    }

    return false;
}

fn pushed_from(target: *Selectors, source: []const Selector) u32 {
    assert(source.len <= std.math.maxInt(u32));

    var dropped: u32 = 0;

    for (source) |selector| {
        if (target.full()) {
            dropped += 1;
        } else {
            target.push(selector);
        }
    }

    assert(dropped <= source.len);

    return dropped;
}

fn selection_resolved_check(resolved: CodeSet, rules: *const Registry) void {
    const rule_count = rules.count();

    assert(rule_count <= rule_count_max);
    if (rule_count < rule_count_max) assert(resolved.bits >> @intCast(rule_count) == 0);
}

fn strength_default(selected: bool, default_on: bool) ?u8 {
    if (selected) return null;
    if (!default_on) return null;
    return 0;
}

fn strongest(current: ?u8, selectors: []const Selector, code: []const u8) ?u8 {
    assert(selectors.len <= std.math.maxInt(u32));
    assert(code.len <= std.math.maxInt(u32));
    if (current) |held| assert(held <= code_text_bytes_max);

    var chosen = current;

    for (selectors) |*selector| {
        if (!selector.matches(code)) continue;

        const strength = selector.specificity();

        if (chosen) |seen| {
            if (seen >= strength) continue;
        }

        chosen = strength;
    }

    if (current) |held| assert(chosen.? >= held);

    return chosen;
}

fn test_rule(code: []const u8, name: []const u8, default_on: bool, group: Rule.Group) Rule {
    assert(code.len <= std.math.maxInt(u32));
    assert(name.len <= std.math.maxInt(u32));
    if (default_on) assert(group == .deprecated or group == .stable);

    return .{
        .citations = &.{},
        .code = code,
        .default_on = default_on,
        .description = "",
        .explanation = "",
        .fix_title = "",
        .fixable = .never,
        .group = group,
        .name = name,
        .severity = .warning,
        .summary = "",
        .url = "",
    };
}

const test_rules = [_]Rule{
    test_rule("TS001", "unused-import", true, .stable),
    test_rule("TS004", "late-future-import", true, .stable),
    test_rule("TS011", "redefined-while-unused", false, .preview),
    test_rule("GL001", "registration-args", true, .stable),
    test_rule("GL015", "unregistered-name", true, .deprecated),
};

fn test_registry() !Registry {
    var registry = try Registry.init(std.testing.allocator, test_rules.len);

    for (&test_rules) |*item| registry.register(item);

    return registry;
}

fn test_selection(
    held: *const Registry,
    text: []const []const u8,
    ignore: []const []const u8,
) !Selection {
    assert(text.len <= std.math.maxInt(u32));
    assert(ignore.len <= std.math.maxInt(u32));

    var selection = try Selection.init(std.testing.allocator, 8);

    selection.preview.enabled = true;
    selection.selected = text.len > 0;

    for (text) |spelled| selection.select.push(Selector.named(held, spelled).?);
    for (ignore) |spelled| selection.ignore.push(Selector.named(held, spelled).?);

    return selection;
}

fn test_resolved(text: []const []const u8, ignore: []const []const u8) !CodeSet {
    assert(text.len <= std.math.maxInt(u32));
    assert(ignore.len <= std.math.maxInt(u32));

    var held = try test_registry();
    defer held.deinit(std.testing.allocator);

    var selection = try test_selection(&held, text, ignore);
    defer selection.deinit(std.testing.allocator);

    return selection.resolve(&held);
}

test Selection {
    const gpa = std.testing.allocator;
    var registry = try test_registry();
    defer registry.deinit(gpa);

    var selection: Selection = try .init(gpa, 8);
    defer selection.deinit(gpa);

    const linter = Selector.named(&registry, "TS").?;
    const late = Selector.named(&registry, "late-future-import").?;

    selection.replace(.select);

    try selection.push(.select, linter);
    try selection.push(.ignore, late);

    const enabled = selection.resolve(&registry);

    try std.testing.expect(selection.is_selected());
    try std.testing.expectEqual(@as(u32, 1), selection.count_of(.ignore));
    try std.testing.expect(enabled.contains(0));
    try std.testing.expect(!enabled.contains(1));
    try std.testing.expect(!enabled.contains(3));
}

test "an ignore composes over the select before it" {
    const enabled = try test_resolved(&.{"TS"}, &.{"TS00"});

    try std.testing.expect(!enabled.contains(0));
    try std.testing.expect(!enabled.contains(1));
    try std.testing.expect(enabled.contains(2));
    try std.testing.expect(!enabled.contains(3));
}

test "a group selector names the rules of its own ten" {
    const enabled = try test_resolved(&.{"TS00"}, &.{});

    try std.testing.expect(enabled.contains(0));
    try std.testing.expect(enabled.contains(1));
    try std.testing.expect(!enabled.contains(2));
}

test "the all selector names every rule" {
    const enabled = try test_resolved(&.{"ALL"}, &.{});

    try std.testing.expect(enabled.contains(0));
    try std.testing.expect(enabled.contains(1));
    try std.testing.expect(enabled.contains(2));
    try std.testing.expect(enabled.contains(3));
}

test "a whole code names the one rule it spells" {
    const enabled = try test_resolved(&.{"TS011"}, &.{});

    try std.testing.expect(!enabled.contains(0));
    try std.testing.expect(enabled.contains(2));
}

test "a prefix stays inside its own linter" {
    const enabled = try test_resolved(&.{"GL"}, &.{});

    try std.testing.expect(!enabled.contains(0));
    try std.testing.expect(!enabled.contains(1));
    try std.testing.expect(enabled.contains(3));
}

test "a preview rule waits for the preview flag unless named exactly" {
    var held = try test_registry();
    defer held.deinit(std.testing.allocator);

    var selection = try Selection.init(std.testing.allocator, 8);
    defer selection.deinit(std.testing.allocator);

    selection.select.push(Selector.all);
    selection.selected = true;

    try std.testing.expect(!selection.resolve(&held).contains(2));

    selection.preview_set(.{ .enabled = true });

    try std.testing.expect(selection.resolve(&held).contains(2));

    selection.preview_set(.{ .enabled = true, .explicit = true });

    try std.testing.expect(!selection.resolve(&held).contains(2));

    selection.extend_select.push(Selector.named(&held, "TS011").?);

    try std.testing.expect(selection.resolve(&held).contains(2));
}

test "a deprecated rule is reached only by name and only outside preview" {
    var held = try test_registry();
    defer held.deinit(std.testing.allocator);

    var selection = try Selection.init(std.testing.allocator, 8);
    defer selection.deinit(std.testing.allocator);

    selection.select.push(Selector.all);
    selection.selected = true;

    try std.testing.expect(!selection.resolve(&held).contains(4));

    selection.select.push(Selector.named(&held, "GL015").?);

    try std.testing.expect(selection.resolve(&held).contains(4));

    selection.preview.enabled = true;

    try std.testing.expect(!selection.resolve(&held).contains(4));
}

test "a name selects the rule that carries it" {
    var held = try test_registry();
    defer held.deinit(std.testing.allocator);

    const selector = Selector.named(&held, "late-future-import").?;

    try std.testing.expect(selector.is_exact("TS004"));
    try std.testing.expectEqual(@as(u8, 5), selector.specificity());
}

test "an external prefix exempts the codes under it" {
    var selection = try Selection.init(std.testing.allocator, 8);
    defer selection.deinit(std.testing.allocator);

    selection.external.push(Selector.of("DJ").?);
    selection.external.push(Selector.all);

    try std.testing.expect(selection.is_external("DJ001"));
    try std.testing.expect(!selection.is_external("TS001"));
    try std.testing.expect(!selection.is_external(""));
}

test "an overlay replaces the selection when it selects and extends otherwise" {
    var held = try test_registry();
    defer held.deinit(std.testing.allocator);

    var base = try test_selection(&held, &.{"TS"}, &.{"TS00"});
    defer base.deinit(std.testing.allocator);

    var over = try Selection.init(std.testing.allocator, 8);
    defer over.deinit(std.testing.allocator);

    over.extend_select.push(Selector.named(&held, "GL").?);
    over.ignore.push(Selector.named(&held, "GL015").?);

    try std.testing.expectEqual(@as(u32, 0), base.overlay(&over));
    try std.testing.expectEqual(@as(u32, 1), base.count_of(.select));
    try std.testing.expectEqual(@as(u32, 1), base.count_of(.extend_select));
    try std.testing.expectEqual(@as(u32, 2), base.count_of(.ignore));

    over.selected = true;

    over.select.push(Selector.named(&held, "GL001").?);

    try std.testing.expectEqual(@as(u32, 0), base.overlay(&over));
    try std.testing.expect(base.is_selected());
    try std.testing.expectEqual(@as(u32, 1), base.count_of(.select));
    try std.testing.expect(base.select.const_slice()[0].is_exact("GL001"));
    try std.testing.expectEqual(@as(u32, 1), base.count_of(.extend_select));
    try std.testing.expectEqual(@as(u32, 1), base.count_of(.ignore));
}

test "an overlay counts the selectors that did not fit" {
    var held = try test_registry();
    defer held.deinit(std.testing.allocator);

    var base = try Selection.init(std.testing.allocator, 1);
    defer base.deinit(std.testing.allocator);

    var over = try Selection.init(std.testing.allocator, 8);
    defer over.deinit(std.testing.allocator);

    over.ignore.push(Selector.named(&held, "GL").?);
    over.ignore.push(Selector.named(&held, "TS").?);

    try std.testing.expectEqual(@as(u32, 1), base.overlay(&over));
    try std.testing.expectEqual(@as(u32, 1), base.count_of(.ignore));
}

test "a push past a full list is refused" {
    var held = try test_registry();
    defer held.deinit(std.testing.allocator);

    var selection = try Selection.init(std.testing.allocator, 1);
    defer selection.deinit(std.testing.allocator);

    const linter = Selector.named(&held, "GL").?;

    try selection.push(.unfixable, linter);
    try std.testing.expectError(error.SelectorsExhausted, selection.push(.unfixable, linter));
    try std.testing.expectEqual(@as(u32, 1), selection.count_of(.unfixable));
    try std.testing.expectEqual(@as(u32, 0), selection.count_of(.fixable));
}

test "selectors read takes an array of names and reports each fault" {
    const gpa = std.testing.allocator;
    var held = try test_registry();
    defer held.deinit(gpa);

    var document: json.DocumentType(.{ .node_count_max = 16, .text_bytes_max = 128 }) = undefined;

    const source =
        \\{"good": ["TS", "late\u002dfuture-import", "XX9"], "bad": "TS", "mixed": ["TS", 4]}
    ;

    try document.parse(source);

    const root = document.root();
    var selection = try Selection.init(gpa, 4);
    defer selection.deinit(gpa);

    const good_names = document.member(root, "good").?;
    const good = selection.selectors_read(&held, &document.base, good_names, .ignore);

    try std.testing.expectEqual(@as(u32, 2), selection.count_of(.ignore));
    try std.testing.expect(selection.ignore.const_slice()[1].is_exact("TS004"));
    try std.testing.expectEqual(Faults{ .selector_count = 1, .value_count = 0 }, good);

    const bad_names = document.member(root, "bad").?;
    const bad = selection.selectors_read(&held, &document.base, bad_names, .ignore);

    try std.testing.expectEqual(Faults{ .selector_count = 0, .value_count = 1 }, bad);

    const mixed_names = document.member(root, "mixed").?;
    const mixed = selection.selectors_read(&held, &document.base, mixed_names, .ignore);

    try std.testing.expectEqual(@as(u32, 3), selection.count_of(.ignore));
    try std.testing.expectEqual(Faults{ .selector_count = 0, .value_count = 1 }, mixed);
}

test "a full target reports a value fault for the selector that did not fit" {
    const gpa = std.testing.allocator;
    var held = try test_registry();
    defer held.deinit(gpa);

    var document: json.DocumentType(.{ .node_count_max = 8, .text_bytes_max = 64 }) = undefined;

    const source =
        \\["TS", "GL"]
    ;

    try document.parse(source);

    var selection = try Selection.init(gpa, 1);
    defer selection.deinit(gpa);

    const root = document.root();
    const faults = selection.selectors_read(&held, &document.base, root, .extend_select);

    try std.testing.expectEqual(@as(u32, 1), selection.count_of(.extend_select));
    try std.testing.expectEqual(Faults{ .selector_count = 0, .value_count = 1 }, faults);
}
