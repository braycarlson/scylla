const std = @import("std");
const assert = std.debug.assert;
const bounded = @import("../../stdx/bounded.zig");
const CodeSet = @import("code_set.zig");
const FixedMapType = @import("../../stdx/bounded/fixed_map.zig").FixedMapType;
const Rule = @import("rule.zig");
const Selection = @import("selection.zig");
const code_text_bytes_max = Rule.code_text_bytes_max;
const rule_count_max = CodeSet.rule_count_max;

by_code: FixedMapType(u32),
rules: bounded.ArrayType(Rule),

const Registry = @This();
pub const CapacityError = error{TargetExhausted};

pub fn init(gpa: std.mem.Allocator, rule_count_capacity: u32) std.mem.Allocator.Error!Registry {
    assert(rule_count_capacity > 0);
    assert(rule_count_capacity <= rule_count_max);

    var by_code = try FixedMapType(u32).init(gpa, rule_count_capacity);
    errdefer by_code.deinit(gpa);

    const held = try bounded.ArrayType(Rule).init(gpa, rule_count_capacity);
    const registry: Registry = .{ .by_code = by_code, .rules = held };

    assert(registry.count() == 0);

    return registry;
}

pub fn deinit(registry: *Registry, gpa: std.mem.Allocator) void {
    assert(registry.by_code.count() == registry.rules.count());

    registry.by_code.deinit(gpa);
    registry.rules.deinit(gpa);
    registry.* = undefined;
}

pub fn register(registry: *Registry, item: *const Rule) void {
    const rule_index = registry.rules.count();

    assert(rule_index < registry.rules.capacity());
    assert(code_number_of(item.code) != null);
    assert(item.name.len > 0);
    assert(item.name.len <= Rule.name_bytes_max);
    assert(registry.by_code.get(item.code) == null);

    registry.by_code.insert(item.code, rule_index) catch |err| switch (err) {
        error.Duplicate => unreachable,
        error.Overflow => unreachable,
    };

    registry.rules.push(item.*);

    assert(registry.count() == rule_index + 1);
}

pub fn at(registry: *const Registry, rule_index: u32) *const Rule {
    assert(rule_index < registry.count());

    const held = &registry.rules.const_slice()[rule_index];

    assert(held.code.len > 0);

    return held;
}

pub fn codes_written(registry: *const Registry, target: []u8, codes: CodeSet) CapacityError!u32 {
    assert(registry.count() <= rule_count_max);
    assert(target.len <= std.math.maxInt(u32));
    if (registry.count() < rule_count_max) assert(codes.bits >> @intCast(registry.count()) == 0);

    var length: u32 = 0;

    for (0..registry.count()) |rule_index| {
        if (!codes.contains(@intCast(rule_index))) continue;

        const code = registry.at(@intCast(rule_index)).code;
        const separator: []const u8 = if (length > 0) ", " else "";
        if (length + separator.len + code.len > target.len) return error.TargetExhausted;

        @memcpy(target[length..][0..separator.len], separator);
        length += @intCast(separator.len);

        @memcpy(target[length..][0..code.len], code);
        length += @intCast(code.len);
    }

    assert(length <= target.len);

    if (length == 0) assert(codes.intersect_with(.with_all(registry.count())).is_empty());

    return length;
}

pub fn count(registry: *const Registry) u32 {
    const held = registry.rules.count();

    assert(held == registry.by_code.count());
    assert(held <= registry.rules.capacity());

    return held;
}

pub fn find(registry: *const Registry, code: []const u8) ?*const Rule {
    assert(code.len <= std.math.maxInt(u32));

    const rule_index = registry.index_of(code) orelse return null;
    const held = registry.at(rule_index);

    assert(std.mem.eql(u8, held.code, code));

    return held;
}

pub fn find_name(registry: *const Registry, name: []const u8) ?*const Rule {
    assert(name.len <= std.math.maxInt(u32));

    const rule_index = registry.index_of_name(name) orelse return null;
    const held = registry.at(rule_index);

    assert(std.mem.eql(u8, held.name, name));

    return held;
}

pub fn index_of(registry: *const Registry, code: []const u8) ?u32 {
    if (code.len == 0) return null;
    if (code.len > code_text_bytes_max) return null;

    const found = registry.by_code.get(code);

    if (found) |rule_index| assert(rule_index < registry.count());

    return found;
}

pub fn index_of_name(registry: *const Registry, name: []const u8) ?u32 {
    if (name.len == 0) return null;

    assert(registry.count() <= rule_count_max);

    for (registry.rules.const_slice(), 0..) |*item, rule_index| {
        if (std.mem.eql(u8, item.name, name)) {
            assert(rule_index < registry.rules.const_slice().len);

            return @intCast(rule_index);
        }
    }

    return null;
}

pub fn slice(registry: *const Registry) []const Rule {
    const rules = registry.rules.const_slice();

    assert(rules.len == registry.by_code.count());

    return rules;
}

fn codes_distinct(rules: []const Rule) bool {
    assert(rules.len <= rule_count_max);

    for (rules, 0..) |*item, position| {
        for (rules[position + 1 ..]) |*other| {
            if (std.mem.eql(u8, item.code, other.code)) return false;
        }
    }

    return true;
}

fn code_number_of(code: []const u8) ?u32 {
    if (code.len > code_text_bytes_max) return null;

    const letters = code_prefix_of(code).len;
    if (letters == 0) return null;
    if (letters == code.len) return null;

    var value: u32 = 0;

    for (code[letters..]) |digit| {
        if (!std.ascii.isDigit(digit)) return null;

        value = value * 10 + (digit - '0');
    }

    return value;
}

fn code_prefix_of(code: []const u8) []const u8 {
    assert(code.len <= std.math.maxInt(u32));

    var letters: usize = 0;

    for (code) |byte| {
        if (!std.ascii.isUpper(byte)) break;

        letters += 1;
    }

    assert(letters <= code.len);

    return code[0..letters];
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

test Registry {
    const gpa = std.testing.allocator;
    const unused = test_rule("TS001", "unused-import", true, .stable);
    const late = test_rule("TS004", "late-future-import", true, .stable);
    var registry: Registry = try .init(gpa, 8);
    defer registry.deinit(gpa);

    registry.register(&unused);
    registry.register(&late);

    const found = registry.find("TS004") orelse return error.TestUnexpectedResult;

    try std.testing.expectEqualStrings("late-future-import", found.name);
    try std.testing.expectEqual(@as(?u32, 0), registry.index_of_name("unused-import"));
    try std.testing.expectEqual(@as(u32, 2), registry.count());
}

test "a table with a code twice is refused where it is reserved" {
    const doubled = [_]Rule{
        test_rule("TS001", "first", true, .stable),
        test_rule("TS001", "second", true, .stable),
    };

    try std.testing.expect(!codes_distinct(&doubled));
    try std.testing.expect(codes_distinct(&test_rules));
}

test "an unknown code names no rule at all" {
    var held = try test_registry();
    defer held.deinit(std.testing.allocator);

    try std.testing.expectEqual(null, held.index_of("TS501"));
    try std.testing.expect(held.find("TS501") == null);
    try std.testing.expect(Selection.Selector.named(&held, "TS501") == null);
    try std.testing.expect(Selection.Selector.named(&held, "XX") == null);
}

test "a known code reads back its own row" {
    var held = try test_registry();
    defer held.deinit(std.testing.allocator);

    const item = held.find("TS004").?;

    try std.testing.expectEqualStrings("late-future-import", item.name);
    try std.testing.expectEqual(Rule.Fixable.never, item.fixable);
    try std.testing.expect(item.severity == .warning);
    try std.testing.expectEqual(@as(u32, 5), held.count());
    try std.testing.expectEqual(@as(u32, 1), held.index_of("TS004"));
    try std.testing.expectEqual(@as(u32, 1), held.index_of_name("late-future-import"));
}

test "a code number reads its digits and refuses everything else" {
    try std.testing.expectEqual(@as(?u32, 42), code_number_of("TS042"));
    try std.testing.expectEqual(@as(?u32, 401), code_number_of("F401"));
    try std.testing.expectEqual(@as(?u32, 1), code_number_of("E1"));
    try std.testing.expectEqual(@as(?u32, 1234), code_number_of("PRJ1234"));
    try std.testing.expectEqual(@as(?u32, null), code_number_of(""));
    try std.testing.expectEqual(@as(?u32, null), code_number_of("042"));
    try std.testing.expectEqual(@as(?u32, null), code_number_of("TS"));
    try std.testing.expectEqual(@as(?u32, null), code_number_of("TSxyz"));
    try std.testing.expectEqual(@as(?u32, null), code_number_of("TS04x"));
    try std.testing.expectEqual(@as(?u32, null), code_number_of("ts042"));
    try std.testing.expectEqual(@as(?u32, null), code_number_of("ABCDEF123"));
    try std.testing.expectEqualStrings("GL", code_prefix_of("GL015"));
    try std.testing.expectEqualStrings("E", code_prefix_of("E1"));
    try std.testing.expectEqualStrings("", code_prefix_of("01"));
}

test "a written list spells every code it holds" {
    const gpa = std.testing.allocator;

    const rules = [_]Rule{
        test_rule("TS002", "second", true, .stable),
        test_rule("GL007", "seventh", true, .stable),
        test_rule("TS012", "twelfth", true, .stable),
    };

    var registry: Registry = try .init(gpa, rules.len);
    defer registry.deinit(gpa);

    for (&rules) |*item| registry.register(item);

    var target: [64]u8 = @splat(0);
    const length = try registry.codes_written(&target, .of_bits((1 << 0) | (1 << 2)));

    try std.testing.expectEqualStrings("TS002, TS012", target[0..length]);
    try std.testing.expectEqual(@as(u32, 0), try registry.codes_written(&target, .empty));

    var small: [8]u8 = @splat(0);

    try std.testing.expectError(
        error.TargetExhausted,
        registry.codes_written(&small, .of_bits((1 << 0) | (1 << 2))),
    );
}
