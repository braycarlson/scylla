const std = @import("std");
const assert = std.debug.assert;

pub fn TimingsType(comptime Stage: type, comptime rule_count_max: u32) type {
    if (@typeInfo(Stage) != .@"enum") {
        @compileError("TimingsType(" ++ @typeName(Stage) ++ ") needs an enum of stages");
    }

    if (rule_count_max == 0) {
        @compileError("TimingsType(" ++ @typeName(Stage) ++ ") needs room for one rule");
    }

    return struct {
        documents_count: u64,
        rules: [rule_count_max]u64,
        stages: std.EnumArray(Stage, u64),

        const Timings = @This();

        pub const zero: Timings = .{
            .documents_count = 0,
            .rules = @splat(0),
            .stages = .initFill(0),
        };

        pub fn document_count(timings: *const Timings) u64 {
            return timings.documents_count;
        }

        pub fn document_record(timings: *Timings) void {
            timings.documents_count +|= 1;

            assert(timings.documents_count > 0);
        }

        fn rule_add(timings: *Timings, rule_index: u32, nanoseconds: u64) void {
            assert(rule_index < rule_count_max);

            timings.rules[rule_index] +|= nanoseconds;
        }

        pub fn rule_at(timings: *const Timings, rule_index: u32) u64 {
            assert(rule_index < rule_count_max);

            return timings.rules[rule_index];
        }

        pub fn rule_nanoseconds(timings: *Timings) *[rule_count_max]u64 {
            return &timings.rules;
        }

        pub fn stage_add(timings: *Timings, stage: Stage, nanoseconds: u64) void {
            const held = timings.stages.getPtr(stage);

            held.* +|= nanoseconds;
        }

        pub fn stage_at(timings: *const Timings, stage: Stage) u64 {
            return timings.stages.get(stage);
        }

        pub fn total(timings: *const Timings) u64 {
            var sum: u64 = 0;

            for (timings.stages.values) |stage| sum +|= stage;
            for (timings.stages.values) |stage| assert(stage <= sum);

            return sum;
        }
    };
}

const TestStage = enum {
    first,
    second,
};

const TestTimings = TimingsType(TestStage, 4);

test TimingsType {
    var timings = TestTimings.zero;

    timings.document_record();
    timings.stage_add(.first, 7);
    timings.rule_nanoseconds()[2] += 5;

    try std.testing.expectEqual(@as(u64, 1), timings.document_count());
    try std.testing.expectEqual(@as(u64, 7), timings.total());
    try std.testing.expectEqual(@as(u64, 5), timings.rule_at(2));
    try std.testing.expectEqual(@as(u64, 0), timings.rule_at(1));
    try std.testing.expectEqual(@as(u64, 0), timings.stage_at(.second));
}

test "a timings table adds each stage and counts documents" {
    var timings = TestTimings.zero;

    try std.testing.expectEqual(@as(u64, 0), timings.rule_at(3));
    try std.testing.expectEqual(@as(u64, 0), timings.document_count());

    timings.document_record();
    timings.stage_add(.second, 7);
    timings.stage_add(.second, 5);
    timings.rule_add(0, 3);

    try std.testing.expectEqual(@as(u64, 1), timings.document_count());
    try std.testing.expectEqual(@as(u64, 12), timings.stage_at(.second));
    try std.testing.expectEqual(@as(u64, 0), timings.stage_at(.first));
    try std.testing.expectEqual(@as(u64, 12), timings.total());
    try std.testing.expect(timings.rule_at(0) >= 3);
}

test "a timings table saturates rather than wrapping" {
    var timings = TestTimings.zero;
    const most = std.math.maxInt(u64);

    timings.stage_add(.first, most);
    timings.stage_add(.first, 1);
    timings.stage_add(.second, 1);
    timings.rule_add(1, most);
    timings.rule_add(1, 1);

    try std.testing.expectEqual(most, timings.stage_at(.first));
    try std.testing.expectEqual(@as(u64, 1), timings.stage_at(.second));
    try std.testing.expectEqual(most, timings.total());
    try std.testing.expectEqual(most, timings.rule_at(1));
}
