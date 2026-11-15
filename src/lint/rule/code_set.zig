const std = @import("std");
const assert = std.debug.assert;

bits: u128,

const CodeSet = @This();
pub const empty: CodeSet = .{ .bits = 0 };
pub const rule_count_max: u32 = 128;

comptime {
    assert(rule_count_max == @bitSizeOf(u128));
}

pub fn with_all(rule_count: u32) CodeSet {
    assert(rule_count <= rule_count_max);

    if (rule_count == rule_count_max) return .{ .bits = std.math.maxInt(u128) };

    const bits = (@as(u128, 1) << @intCast(rule_count)) - 1;

    assert(@popCount(bits) == rule_count);

    return .{ .bits = bits };
}

pub fn of_bits(bits: u128) CodeSet {
    return .{ .bits = bits };
}

pub fn contains(set: CodeSet, rule_index: u32) bool {
    assert(rule_index < rule_count_max);

    return set.bits & (@as(u128, 1) << @intCast(rule_index)) != 0;
}

pub fn count(set: CodeSet) u32 {
    const held: u32 = @popCount(set.bits);

    assert(held <= rule_count_max);

    return held;
}

pub fn difference_with(set: CodeSet, other: CodeSet) CodeSet {
    const result: CodeSet = .{ .bits = set.bits & ~other.bits };

    assert(result.intersect_with(other).is_empty());
    assert(result.count() <= set.count());

    return result;
}

pub fn insert(set: *CodeSet, rule_index: u32) void {
    assert(rule_index < rule_count_max);

    set.bits |= @as(u128, 1) << @intCast(rule_index);

    assert(set.contains(rule_index));
}

pub fn intersect_with(set: CodeSet, other: CodeSet) CodeSet {
    const result: CodeSet = .{ .bits = set.bits & other.bits };

    assert(result.count() <= set.count());
    assert(result.count() <= other.count());

    return result;
}

pub fn is_empty(set: CodeSet) bool {
    return set.bits == 0;
}

fn remove(set: *CodeSet, rule_index: u32) void {
    assert(rule_index < rule_count_max);

    set.bits &= ~(@as(u128, 1) << @intCast(rule_index));

    assert(!set.contains(rule_index));
}

pub fn union_with(set: CodeSet, other: CodeSet) CodeSet {
    const result: CodeSet = .{ .bits = set.bits | other.bits };

    assert(result.count() >= set.count());
    assert(result.count() >= other.count());

    return result;
}

test CodeSet {
    var enabled: CodeSet = .empty;

    enabled.insert(2);
    enabled.insert(5);

    const ignored = CodeSet.of_bits(1 << 5);
    const kept = enabled.difference_with(ignored);

    try std.testing.expect(kept.contains(2));
    try std.testing.expect(!kept.contains(5));
    try std.testing.expectEqual(@as(u32, 1), kept.count());
}

test "a code set holds what it is given" {
    var held = CodeSet.empty;

    try std.testing.expect(!held.contains(3));

    held.insert(3);

    try std.testing.expect(held.contains(3));
    try std.testing.expect(!held.contains(4));

    held.remove(3);

    try std.testing.expect(!held.contains(3));
    try std.testing.expect(CodeSet.with_all(5).contains(4));
    try std.testing.expect(!CodeSet.with_all(5).contains(5));
    try std.testing.expect(CodeSet.with_all(rule_count_max).contains(rule_count_max - 1));
}

test "code sets combine as sets" {
    const low = CodeSet.with_all(4);
    const odd = CodeSet.of_bits(0b1010_1010);

    try std.testing.expectEqual(CodeSet.of_bits(0b1010), low.intersect_with(odd));
    try std.testing.expectEqual(CodeSet.of_bits(0b0101), low.difference_with(odd));
    try std.testing.expectEqual(CodeSet.of_bits(0b1010_1111), low.union_with(odd));
    try std.testing.expectEqual(4, odd.count());
    try std.testing.expect(low.difference_with(low).is_empty());
    try std.testing.expect(!low.is_empty());
}
