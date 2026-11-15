const std = @import("std");
const assert = std.debug.assert;
const bounded = @import("../../stdx/bounded.zig");
const Clock = @import("../../stdx/timing/clock.zig");
const CodeSet = @import("code_set.zig");
const Diagnostics = @import("../diagnostics.zig");
const FileID = @import("../../stdx/file_id.zig").FileID;
const Fixes = @import("../fixes.zig");
const LineIndex = @import("../../text/line_index.zig").LineIndex;
const Regions = @import("../suppress/regions.zig");
const Registry = @import("registry.zig");
const Rule = @import("rule.zig");
const Sink = @import("sink.zig");
const Applicability = Fixes.Applicability;
const Severity = Diagnostics.Severity;
const rule_count_max = CodeSet.rule_count_max;

const RunnerPolicy = struct {
    enabled: CodeSet,
    fixable: CodeSet,
    safe_fixes: CodeSet,
    severity: [rule_count_max]?Severity,
    unsafe_fixes: CodeSet,

    fn applicability_of(policy: *const RunnerPolicy, rule_index: u32) ?Applicability {
        assert(rule_index < rule_count_max);

        if (policy.unsafe_fixes.contains(rule_index)) return .unsafe;
        if (policy.safe_fixes.contains(rule_index)) return .safe;
        return null;
    }

    fn enables(policy: *const RunnerPolicy, rule_index: u32) bool {
        assert(rule_index < rule_count_max);

        return policy.enabled.contains(rule_index);
    }

    fn fixes(policy: *const RunnerPolicy, rule_index: u32) bool {
        assert(rule_index < rule_count_max);

        return policy.fixable.contains(rule_index);
    }

    fn severity_of(policy: *const RunnerPolicy, rule_index: u32, fallback: Severity) Severity {
        assert(rule_index < rule_count_max);

        return policy.severity[rule_index] orelse fallback;
    }
};

const RunnerTables = struct {
    diagnostics: *Diagnostics,
    file: FileID,
    fixes: *Fixes,
    io: std.Io,
    language: u32,
    lines: *const LineIndex,
    registry: *const Registry,
    suppressions: *Regions,
};

const language_count_max: u32 = 64;

pub fn RunnerType(
    comptime Context: type,
    comptime runs: []const *const fn (*const Context, *Sink) void,
) type {
    if (runs.len == 0) {
        @compileError("RunnerType(" ++ @typeName(Context) ++ ") holds no rule body");
    }

    if (runs.len > rule_count_max) {
        @compileError("RunnerType(" ++ @typeName(Context) ++ ") holds more bodies than rules fit");
    }

    return struct {
        entries: bounded.ArrayType(Entry),

        const Runner = @This();

        pub const Entry = struct {
            languages: u64,
            run: u32,
        };

        pub const Policy = RunnerPolicy;
        pub const Tables = RunnerTables;

        pub fn init(
            gpa: std.mem.Allocator,
            rule_count_capacity: u32,
        ) std.mem.Allocator.Error!Runner {
            assert(rule_count_capacity > 0);
            assert(rule_count_capacity <= rule_count_max);

            const entries = try bounded.ArrayType(Entry).init(gpa, rule_count_capacity);
            return .{ .entries = entries };
        }

        pub fn deinit(runner: *Runner, gpa: std.mem.Allocator) void {
            assert(runner.entries.count() <= rule_count_max);

            runner.entries.deinit(gpa);
            runner.* = undefined;
        }

        fn at(runner: *const Runner, entry_index: u32) Entry {
            assert(entry_index < runner.count());

            return runner.entries.get(entry_index);
        }

        pub fn count(runner: *const Runner) u32 {
            return runner.entries.count();
        }

        fn covers(runner: *const Runner, entry_index: u32, language: u32) bool {
            assert(language < language_count_max);
            assert(entry_index < std.math.maxInt(u32));

            const mask = @as(u64, 1) << @intCast(language);
            return runner.at(entry_index).languages & mask != 0;
        }

        pub fn register(runner: *Runner, languages: u64, run_index: u32) void {
            const entry_index = runner.entries.count();

            assert(entry_index < rule_count_max);
            assert(run_index < runs.len);
            assert(languages != 0);

            runner.entries.push(.{ .languages = languages, .run = run_index });

            assert(runner.count() == entry_index + 1);
        }

        pub fn run(
            runner: *const Runner,
            tables: *const Tables,
            policy: *const Policy,
            context: *const Context,
            nanoseconds: *[rule_count_max]u64,
        ) void {
            assert(runner.count() <= tables.registry.count());

            runner.run_with(tables, policy, context, nanoseconds, RuleSame{});
        }

        fn run_with(
            runner: *const Runner,
            tables: *const Tables,
            policy: *const Policy,
            context: *const Context,
            nanoseconds: *[rule_count_max]u64,
            mapper: anytype,
        ) void {
            assert(tables.language < language_count_max);
            comptime assert(@typeInfo(@TypeOf(mapper)) == .@"struct");

            for (0..runner.count()) |entry_index_usize| {
                const entry_index: u32 = @intCast(entry_index_usize);
                const rule_index = mapper.rule_of(entry_index) orelse continue;

                assert(rule_index < tables.registry.count());

                if (!runner.covers(entry_index, tables.language)) continue;
                if (!policy.enables(rule_index)) continue;

                const held = tables.registry.at(rule_index);

                var sink = Sink.init(&.{
                    .applicability = policy.applicability_of(rule_index),
                    .code = held.code,
                    .diagnostics = tables.diagnostics,
                    .file = tables.file,
                    .fixable = policy.fixes(rule_index),
                    .fixes = tables.fixes,
                    .lines = tables.lines,
                    .rule_index = rule_index,
                    .severity = policy.severity_of(rule_index, held.severity),
                    .suppressions = tables.suppressions,
                });

                const clock = Clock.init(tables.io);

                runner_dispatch(runner.at(entry_index).run, context, &sink);
                nanoseconds[rule_index] +|= clock.nanoseconds();

                assert(!tables.fixes.is_pending());
            }
        }

        fn runner_dispatch(run_index: u32, context: *const Context, sink: *Sink) void {
            assert(run_index < runs.len);

            inline for (runs, 0..) |body, body_index| {
                if (body_index == run_index) body(context, sink);
            }
        }

        const RuleSame = struct {
            fn rule_of(mapper: RuleSame, entry_index: u32) ?u32 {
                _ = mapper;

                assert(entry_index < rule_count_max);

                return entry_index;
            }
        };
    };
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

fn test_report_first_byte(source: *const []const u8, sink: *Sink) void {
    assert(source.len > 0);

    sink.report(.{ .offset = 0, .length = 1 }, "the first byte is reported");
}

fn test_report_nothing(source: *const []const u8, sink: *Sink) void {
    _ = source;
    _ = sink;
}

const test_runs = [_]*const fn (*const []const u8, *Sink) void{
    &test_report_first_byte,
    &test_report_nothing,
};

const TestRunner = RunnerType([]const u8, &test_runs);
const test_run_first_byte: u32 = 0;
const test_run_nothing: u32 = 1;

const TestTables = struct {
    diagnostics: Diagnostics,
    fixes: Fixes,
    index: LineIndex,
    suppressions: Regions,

    fn init(source: []const u8) !TestTables {
        assert(source.len <= std.math.maxInt(u32));

        const gpa = std.testing.allocator;

        var tables: TestTables = .{
            .diagnostics = try Diagnostics.init(gpa, .{
                .related_count_max = 8,
                .row_count_max = 8,
                .text_bytes_max = 1 << 10,
            }),
            .fixes = try Fixes.init(gpa, .{
                .edit_count_max = 4,
                .fix_count_max = 4,
                .text_bytes_max = 1 << 10,
            }),
            .index = try LineIndex.init(gpa, 8),
            .suppressions = try Regions.init(gpa, 4),
        };

        try tables.index.build(source);

        assert(tables.index.count() > 0);

        return tables;
    }

    fn deinit(tables: *TestTables) void {
        const gpa = std.testing.allocator;

        tables.diagnostics.deinit(gpa);
        tables.fixes.deinit(gpa);
        tables.index.deinit(gpa);
        tables.suppressions.deinit(gpa);
    }

    fn bound(tables: *TestTables, registry: *const Registry, language: u32) TestRunner.Tables {
        assert(language < @bitSizeOf(u64));

        return .{
            .diagnostics = &tables.diagnostics,
            .file = FileID.of(0),
            .fixes = &tables.fixes,
            .io = std.testing.io,
            .language = language,
            .lines = &tables.index,
            .registry = registry,
            .suppressions = &tables.suppressions,
        };
    }
};

fn test_policy(enabled: CodeSet) TestRunner.Policy {
    return .{
        .enabled = enabled,
        .fixable = .empty,
        .safe_fixes = .empty,
        .severity = @splat(null),
        .unsafe_fixes = .empty,
    };
}

const TestRuleMapped = struct {
    fn rule_of(mapper: TestRuleMapped, entry_index: u32) ?u32 {
        _ = mapper;

        const mapped = [_]?u32{ 4, 3 };

        assert(entry_index < mapped.len);

        return mapped[entry_index];
    }
};

const TestRuleFirst = struct {
    fn rule_of(mapper: TestRuleFirst, entry_index: u32) ?u32 {
        _ = mapper;

        assert(entry_index < test_runs.len);

        if (entry_index == 0) return 3;
        return null;
    }
};

test RunnerType {
    const gpa = std.testing.allocator;
    const source: []const u8 = "fn main() {}\n";
    var registry = try test_registry();
    defer registry.deinit(gpa);

    var runner: TestRunner = try .init(gpa, 8);
    defer runner.deinit(gpa);

    var tables = try TestTables.init(source);
    defer tables.deinit();

    runner.register(0b01, test_run_first_byte);

    const bound = tables.bound(&registry, 0);
    const policy = test_policy(.with_all(test_rules.len));
    var nanoseconds: [rule_count_max]u64 = @splat(0);

    runner.run(&bound, &policy, &source, &nanoseconds);

    try std.testing.expectEqual(@as(u32, 1), tables.diagnostics.count());
    try std.testing.expectEqualStrings("TS001", tables.diagnostics.slice()[0].code);
}

test "a runner runs the enabled rules of the language and times each" {
    const gpa = std.testing.allocator;
    var held = try test_registry();
    defer held.deinit(gpa);

    var runner = try TestRunner.init(gpa, 8);
    defer runner.deinit(gpa);

    runner.register(0b01, test_run_first_byte);
    runner.register(0b10, test_run_first_byte);
    runner.register(0b11, test_run_nothing);
    runner.register(0b11, test_run_first_byte);

    try std.testing.expectEqual(@as(u32, 4), runner.count());
    try std.testing.expect(runner.covers(0, 0));
    try std.testing.expect(!runner.covers(0, 1));
    try std.testing.expect(runner.covers(2, 1));

    var enabled = CodeSet.empty;

    enabled.insert(0);
    enabled.insert(1);
    enabled.insert(2);

    const policy = test_policy(enabled);
    const source: []const u8 = "fn main() {}\n";
    var tables = try TestTables.init(source);
    defer tables.deinit();

    const bound = tables.bound(&held, 0);
    var nanoseconds: [rule_count_max]u64 = @splat(0);

    runner.run(&bound, &policy, &source, &nanoseconds);

    try std.testing.expectEqual(@as(u32, 1), tables.diagnostics.count());
    try std.testing.expectEqual(@as(?u32, 0), tables.diagnostics.slice()[0].rule);
    try std.testing.expectEqualStrings("TS001", tables.diagnostics.slice()[0].code);
    try std.testing.expectEqual(@as(u64, 0), nanoseconds[3]);
}

test "a runner maps each entry to the rule the caller names" {
    const gpa = std.testing.allocator;
    var held = try test_registry();
    defer held.deinit(gpa);

    var runner = try TestRunner.init(gpa, 2);
    defer runner.deinit(gpa);

    runner.register(0b01, test_run_first_byte);
    runner.register(0b01, test_run_first_byte);

    var enabled = CodeSet.empty;

    enabled.insert(3);

    const policy = test_policy(enabled);
    const source: []const u8 = "fn main() {}\n";
    var tables = try TestTables.init(source);
    defer tables.deinit();

    const bound = tables.bound(&held, 0);
    var nanoseconds: [rule_count_max]u64 = @splat(0);

    runner.run_with(&bound, &policy, &source, &nanoseconds, TestRuleMapped{});

    try std.testing.expectEqual(@as(u32, 1), tables.diagnostics.count());

    const row = tables.diagnostics.slice()[0];

    try std.testing.expectEqual(@as(?u32, 3), row.rule);
    try std.testing.expectEqualStrings("GL001", row.code);
    try std.testing.expectEqual(@as(u64, 0), nanoseconds[4]);

    runner.run_with(&bound, &policy, &source, &nanoseconds, TestRuleFirst{});

    try std.testing.expectEqual(@as(u32, 2), tables.diagnostics.count());
}

test "a policy maps each rule to its fixes and severity" {
    var policy = test_policy(.with_all(3));

    policy.fixable.insert(1);
    policy.safe_fixes.insert(1);
    policy.unsafe_fixes.insert(2);
    policy.severity[2] = .@"error";

    try std.testing.expect(policy.enables(2));
    try std.testing.expect(!policy.enables(3));
    try std.testing.expect(policy.fixes(1));
    try std.testing.expect(!policy.fixes(0));
    try std.testing.expectEqual(@as(?Applicability, .safe), policy.applicability_of(1));
    try std.testing.expectEqual(@as(?Applicability, .unsafe), policy.applicability_of(2));
    try std.testing.expectEqual(@as(?Applicability, null), policy.applicability_of(0));
    try std.testing.expectEqual(Severity.@"error", policy.severity_of(2, .warning));
    try std.testing.expectEqual(Severity.hint, policy.severity_of(0, .hint));
}
