const std = @import("std");
const assert = std.debug.assert;
const scan = @import("../text/scan.zig");

const Operator = enum {
    caret,
    compatible,
    equal,
    greater,
    greater_equal,
    less,
    less_equal,
    not_equal,
};

const Parts = [part_count]u64;

const Spelled = struct {
    operator: Operator,
    rest: []const u8,
};

const Spelling = struct {
    text: []const u8,
    operator: Operator,
};

pub const CapacityError = error{ClausesExhausted};
pub const Error = CapacityError || SyntaxError;
pub const SyntaxError = error{ClauseInvalid};

pub const Check = struct {
    held: []const u8,
    requirement: []const u8,
};

pub const clause_count_max: u32 = 16;
const part_count: u32 = 3;

const spellings = [_]Spelling{
    .{ .text = "~=", .operator = .compatible },
    .{ .text = "==", .operator = .equal },
    .{ .text = ">=", .operator = .greater_equal },
    .{ .text = "<=", .operator = .less_equal },
    .{ .text = "!=", .operator = .not_equal },
    .{ .text = ">", .operator = .greater },
    .{ .text = "<", .operator = .less },
    .{ .text = "^", .operator = .caret },
    .{ .text = "=", .operator = .equal },
};

comptime {
    assert(part_count > 0);
    assert(clause_count_max > 0);
}

pub fn satisfies(check: *const Check) Error!bool {
    const requirement = check.requirement;
    var satisfied = true;
    var start: usize = 0;

    for (0..clause_count_max) |_| {
        if (start >= requirement.len) return satisfied;

        const end = std.mem.findScalarPos(u8, requirement, start, ',') orelse requirement.len;

        assert(end >= start);
        assert(end <= requirement.len);

        if (!try clause_satisfied(check.held, requirement[start..end])) satisfied = false;

        start = end + 1;
    }

    if (start < requirement.len) return error.ClausesExhausted;
    return satisfied;
}

fn clause_satisfied(held: []const u8, clause: []const u8) SyntaxError!bool {
    assert(held.len <= std.math.maxInt(u32));
    assert(clause.len <= std.math.maxInt(u32));

    const trimmed = std.mem.trim(u8, clause, scan.ascii_whitespace);
    if (trimmed.len == 0) return true;

    const spelled = operator_of(trimmed);
    const wanted = std.mem.trim(u8, spelled.rest, scan.ascii_whitespace);
    if (wanted.len == 0) return error.ClauseInvalid;
    if (!std.ascii.isDigit(wanted[0])) return error.ClauseInvalid;

    const left = numbered(held);
    const right = numbered(wanted);
    const spelled_count = part_count_of(wanted);
    const order = std.mem.order(u64, &left, &right);

    assert(spelled_count > 0);
    assert(spelled_count <= part_count);

    return switch (spelled.operator) {
        .caret => order != .lt and left[0] == right[0],
        .compatible => order != .lt and same_series(&left, &right, spelled_count),
        .equal => prefix_equal(&left, &right, spelled_count),
        .greater => order == .gt,
        .greater_equal => order != .lt,
        .less => order == .lt,
        .less_equal => order != .gt,
        .not_equal => !prefix_equal(&left, &right, spelled_count),
    };
}

fn numbered(version: []const u8) Parts {
    assert(version.len <= std.math.maxInt(u32));

    var parts: Parts = @splat(0);
    var fields = std.mem.splitScalar(u8, version, '.');
    var index: u32 = 0;

    for (0..part_count) |_| {
        const field = fields.next() orelse break;

        assert(index < part_count);

        parts[index] = numbered_field(field);
        index += 1;
    }

    assert(index > 0);
    assert(index <= part_count);

    return parts;
}

fn numbered_field(field: []const u8) u64 {
    assert(field.len <= std.math.maxInt(u32));

    var value: u64 = 0;
    var digit_count: usize = 0;

    for (field) |byte| {
        if (!std.ascii.isDigit(byte)) break;

        value = value *| 10 +| (byte - '0');
        digit_count += 1;
    }

    assert(digit_count <= field.len);
    if (digit_count == 0) assert(value == 0);

    return value;
}

fn operator_of(clause: []const u8) Spelled {
    assert(clause.len > 0);

    for (spellings) |spelling| {
        if (std.mem.startsWith(u8, clause, spelling.text)) {
            assert(spelling.text.len <= clause.len);

            return .{ .operator = spelling.operator, .rest = clause[spelling.text.len..] };
        }
    }

    return .{ .operator = .equal, .rest = clause };
}

fn part_count_of(version: []const u8) u32 {
    assert(version.len <= std.math.maxInt(u32));

    const dot_count = std.mem.count(u8, version, ".");
    const field_count = @min(dot_count + 1, part_count);

    assert(field_count > 0);
    assert(field_count <= part_count);

    return @intCast(field_count);
}

fn prefix_equal(left: *const Parts, right: *const Parts, spelled_count: u32) bool {
    assert(spelled_count > 0);
    assert(spelled_count <= part_count);

    return std.mem.eql(u64, left[0..spelled_count], right[0..spelled_count]);
}

fn same_series(left: *const Parts, right: *const Parts, spelled_count: u32) bool {
    assert(spelled_count > 0);
    assert(spelled_count <= part_count);

    if (spelled_count <= 1) return true;

    const held_count = spelled_count - 1;
    return std.mem.eql(u64, left[0..held_count], right[0..held_count]);
}

fn test_satisfies(held: []const u8, requirement: []const u8) Error!bool {
    assert(held.len <= std.math.maxInt(u32));
    assert(requirement.len <= std.math.maxInt(u32));

    return satisfies(&.{ .held = held, .requirement = requirement });
}

test satisfies {
    const check: Check = .{ .held = "1.4.0", .requirement = ">=1.2, <2" };
    const garbled: Check = .{ .held = "1.4.0", .requirement = ">=one" };

    try std.testing.expect(try satisfies(&check));
    try std.testing.expectError(error.ClauseInvalid, satisfies(&garbled));
}

test "an empty requirement is satisfied by every version" {
    try std.testing.expect(try test_satisfies("1.2.3", ""));
    try std.testing.expect(try test_satisfies("1.2.3", "   "));
    try std.testing.expect(try test_satisfies("1.2.3", " , "));
}

test "each operator compares the way its spelling says" {
    try std.testing.expect(try test_satisfies("1.2.3", ">=1.2.3"));
    try std.testing.expect(try test_satisfies("1.2.3", ">= 1.2"));
    try std.testing.expect(!try test_satisfies("1.2.3", ">=1.3"));
    try std.testing.expect(try test_satisfies("1.2.3", ">1.2.2"));
    try std.testing.expect(!try test_satisfies("1.2.3", ">1.2.3"));
    try std.testing.expect(try test_satisfies("1.2.3", "<=1.2.3"));
    try std.testing.expect(!try test_satisfies("1.2.3", "<=1.2.2"));
    try std.testing.expect(try test_satisfies("1.2.3", "<2"));
    try std.testing.expect(!try test_satisfies("1.2.3", "<1.2.3"));
    try std.testing.expect(try test_satisfies("1.2.3", "!=1.2.4"));
    try std.testing.expect(!try test_satisfies("1.2.3", "!=1.2"));
}

test "an equality holds over the parts the requirement spells" {
    try std.testing.expect(try test_satisfies("1.2.3", "==1.2.3"));
    try std.testing.expect(try test_satisfies("1.2.3", "==1.2"));
    try std.testing.expect(try test_satisfies("1.2.3", "=1"));
    try std.testing.expect(try test_satisfies("1.2.3", "1.2.3"));
    try std.testing.expect(!try test_satisfies("1.2.3", "==1.2.4"));
    try std.testing.expect(!try test_satisfies("1.2.3", "1.3"));
}

test "a compatible release stays in its series" {
    try std.testing.expect(try test_satisfies("1.2.3", "~=1.2"));
    try std.testing.expect(try test_satisfies("1.9.0", "~=1.2"));
    try std.testing.expect(!try test_satisfies("2.0.0", "~=1.2"));
    try std.testing.expect(try test_satisfies("1.2.9", "~=1.2.3"));
    try std.testing.expect(!try test_satisfies("1.3.0", "~=1.2.3"));
    try std.testing.expect(!try test_satisfies("1.2.2", "~=1.2.3"));
    try std.testing.expect(try test_satisfies("7.0.0", "~=1"));
}

test "a caret stays in its major" {
    try std.testing.expect(try test_satisfies("1.2.3", "^1.2"));
    try std.testing.expect(try test_satisfies("1.9.9", "^1.2.3"));
    try std.testing.expect(!try test_satisfies("2.0.0", "^1.2.3"));
    try std.testing.expect(!try test_satisfies("1.2.2", "^1.2.3"));
}

test "comma clauses all have to hold" {
    try std.testing.expect(try test_satisfies("1.2.3", ">=1.0, <2.0"));
    try std.testing.expect(!try test_satisfies("2.1.0", ">=1.0, <2.0"));
    try std.testing.expect(!try test_satisfies("0.9.0", ">=1.0,<2.0"));
    try std.testing.expect(try test_satisfies("1.2.3", ">=1.0,,<2.0,"));
}

test "a version with a suffix reads its digits only" {
    try std.testing.expectEqual(Parts{ 1, 2, 3 }, numbered("1.2.3-beta"));
    try std.testing.expectEqual(Parts{ 1, 2, 0 }, numbered("1.2"));
    try std.testing.expectEqual(Parts{ 1, 2, 3 }, numbered("1.2.3.4"));
    try std.testing.expectEqual(Parts{ 0, 0, 0 }, numbered(""));
    try std.testing.expectEqual(@as(u32, 3), part_count_of("1.2.3.4"));
    try std.testing.expectEqual(@as(u32, 1), part_count_of("1"));
}

test "a clause that names no version is refused" {
    try std.testing.expectError(error.ClauseInvalid, test_satisfies("0.3.0", "abc"));
    try std.testing.expectError(error.ClauseInvalid, test_satisfies("0.3.0", ">="));
    try std.testing.expectError(error.ClauseInvalid, test_satisfies("1.2.3", "v1.2"));
    try std.testing.expectError(error.ClauseInvalid, test_satisfies("1.2.3", "<1.0, >=x"));
}

test "a requirement with more clauses than the bound is refused" {
    const long = ">=1,>=1,>=1,>=1,>=1,>=1,>=1,>=1,>=1,>=1,>=1,>=1,>=1,>=1,>=1,>=1";

    try std.testing.expect(try test_satisfies("1.2.3", long));
    try std.testing.expectError(error.ClausesExhausted, test_satisfies("1.2.3", long ++ ",>=1"));
}
