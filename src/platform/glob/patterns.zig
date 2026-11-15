const std = @import("std");
const assert = std.debug.assert;
const bounded = @import("../../stdx/bounded.zig");
const glob = @import("engine.zig");
const path_platform = @import("../path/platform.zig");
const StaticAllocator = @import("../../stdx/static_allocator.zig");
const Anchoring = glob.Anchoring;
const Error = glob.Error;
const Row = glob.Row;
const Shape = glob.Shape;
const Span = bounded.Span;
const Token = glob.Token;
const rows_per_pattern: u32 = 8;
const tokens_per_byte: u32 = 4;

pub fn PatternsType(comptime platform: path_platform.Platform) type {
    return struct {
        classes: bounded.ArrayType(u8),
        diagnostic: Diagnostic,
        pending: bounded.ArrayType(Row),
        rows: bounded.ArrayType(Row),
        shapes: bounded.ArrayType(Shape),
        spans: bounded.ArrayType(Row),
        tokens: bounded.ArrayType(Token),
        work: bounded.ArrayType(u8),

        pub const Capacity = struct {
            byte_count_max: u32,
            class_count_max: u32,
            pattern_count_max: u32,
        };

        pub const Diagnostic = glob.Diagnostic;
        pub const Scratch = glob.Scratch;
        const Patterns = @This();
        const Matcher = glob.MatcherType(platform);

        pub fn init(gpa: std.mem.Allocator, capacity: Capacity) std.mem.Allocator.Error!Patterns {
            assert(capacity.pattern_count_max > 0);
            assert(capacity.byte_count_max > 0);
            assert(capacity.class_count_max > 0);

            const row_count_max = capacity.pattern_count_max *| rows_per_pattern;
            const token_count_max = capacity.byte_count_max *| tokens_per_byte;
            const class_bytes_max = capacity.class_count_max * glob.class_bytes;
            var classes: bounded.ArrayType(u8) = try .init(gpa, class_bytes_max);
            errdefer classes.deinit(gpa);

            var pending: bounded.ArrayType(Row) = try .init(gpa, glob.variant_count_max);
            errdefer pending.deinit(gpa);

            var rows: bounded.ArrayType(Row) = try .init(gpa, row_count_max);
            errdefer rows.deinit(gpa);

            var shapes: bounded.ArrayType(Shape) = try .init(gpa, row_count_max);
            errdefer shapes.deinit(gpa);

            var spans: bounded.ArrayType(Row) = try .init(gpa, glob.variant_count_max);
            errdefer spans.deinit(gpa);

            var tokens: bounded.ArrayType(Token) = try .init(gpa, token_count_max);
            errdefer tokens.deinit(gpa);

            const work: bounded.ArrayType(u8) = try .init(gpa, glob.variant_bytes_max);

            return .{
                .classes = classes,
                .diagnostic = .{ .offset = 0 },
                .pending = pending,
                .rows = rows,
                .shapes = shapes,
                .spans = spans,
                .tokens = tokens,
                .work = work,
            };
        }

        pub fn deinit(patterns: *Patterns, gpa: std.mem.Allocator) void {
            assert(patterns.shapes.count() <= patterns.rows.count());
            assert(patterns.rows.capacity() == patterns.shapes.capacity());

            patterns.classes.deinit(gpa);
            patterns.pending.deinit(gpa);
            patterns.rows.deinit(gpa);
            patterns.shapes.deinit(gpa);
            patterns.spans.deinit(gpa);
            patterns.tokens.deinit(gpa);
            patterns.work.deinit(gpa);
            patterns.* = undefined;
        }

        pub fn clear(patterns: *Patterns) void {
            patterns.classes.clear();
            patterns.rows.clear();
            patterns.shapes.clear();
            patterns.tokens.clear();

            assert(patterns.empty());
            assert(patterns.tokens.empty());
        }

        pub fn count(patterns: *const Patterns) u32 {
            assert(patterns.shapes.count() <= patterns.rows.count());

            return patterns.rows.count();
        }

        pub fn empty(patterns: *const Patterns) bool {
            assert(patterns.shapes.count() <= patterns.rows.count());

            return patterns.rows.count() == 0;
        }

        fn matched(patterns: *const Patterns, scratch: *Scratch, subject: []const u8) ?u32 {
            assert(patterns.shapes.count() <= patterns.rows.count());
            assert(scratch.capacity() >= patterns.tokens.capacity());
            assert(subject.len <= std.math.maxInt(u32));

            for (patterns.rows.const_slice(), 0..) |row, index| {
                if (patterns.row_matches(scratch, row, @intCast(index), subject)) {
                    assert(index < patterns.rows.const_slice().len);

                    return @intCast(index);
                }
            }

            return null;
        }

        pub fn matches(patterns: *const Patterns, scratch: *Scratch, subject: []const u8) bool {
            assert(subject.len <= std.math.maxInt(u32));

            return patterns.matched(scratch, subject) != null;
        }

        fn matches_walked(patterns: *const Patterns, scratch: *Scratch, subject: []const u8) bool {
            assert(patterns.shapes.count() <= patterns.rows.count());
            assert(subject.len <= std.math.maxInt(u32));

            const tokens = patterns.tokens.const_slice();
            const classes = patterns.classes.const_slice();

            for (patterns.rows.const_slice()) |row| {
                if (Matcher.matches(row, tokens, classes, scratch, subject)) return true;
            }

            return false;
        }

        pub fn matches_within(
            patterns: *const Patterns,
            scratch: *Scratch,
            rows: Span,
            subject: []const u8,
        ) bool {
            assert(patterns.shapes.count() <= patterns.rows.count());
            assert(rows.end() <= patterns.rows.count());
            assert(subject.len <= std.math.maxInt(u32));

            for (rows.offset..rows.end()) |index| {
                const row = patterns.rows.get(@intCast(index));
                if (patterns.row_matches(scratch, row, @intCast(index), subject)) return true;
            }

            return false;
        }

        pub fn push(patterns: *Patterns, pattern: []const u8) Error!void {
            assert(pattern.len <= std.math.maxInt(u32));

            return patterns.push_anchoring(pattern, .inferred);
        }

        pub fn push_anchored(patterns: *Patterns, pattern: []const u8) Error!void {
            assert(pattern.len <= std.math.maxInt(u32));

            return patterns.push_anchoring(pattern, .anchored);
        }

        pub fn push_anchoring(
            patterns: *Patterns,
            pattern: []const u8,
            anchoring: Anchoring,
        ) Error!void {
            assert(pattern.len <= std.math.maxInt(u32));

            patterns.diagnostic.offset = 0;

            const held = trimmed(pattern);
            if (held.len == 0) return error.Empty;

            patterns.pending.clear();
            patterns.spans.clear();
            patterns.work.clear();

            try glob.expand(
                held,
                &patterns.work,
                &patterns.pending,
                &patterns.spans,
                &patterns.diagnostic,
            );

            const capacity = patterns.tokens.capacity();

            for (patterns.spans.const_slice()) |span| {
                const alternative = patterns.work.const_slice()[span.start..span.end];

                try patterns.anchor(alternative, anchoring, capacity);
            }

            for (0..patterns.rows.capacity() + 1) |_| {
                const shape_count = patterns.shapes.count();
                if (shape_count >= patterns.rows.count()) break;
                if (patterns.shapes.full()) return error.PatternsExhausted;

                const row = patterns.rows.get(shape_count);

                patterns.shapes.push(glob.classify(patterns.tokens.const_slice(), row));
            }

            assert(patterns.shapes.count() == patterns.rows.count());
        }

        pub fn push_unanchored(patterns: *Patterns, pattern: []const u8) Error!void {
            assert(pattern.len <= std.math.maxInt(u32));

            return patterns.push_anchoring(pattern, .unanchored);
        }

        pub fn truncate(patterns: *Patterns, row_count: u32) void {
            assert(row_count <= patterns.rows.count());

            patterns.rows.truncate(row_count);

            if (patterns.shapes.count() > row_count) patterns.shapes.truncate(row_count);

            const token_count: u32 = if (row_count == 0)
                0
            else
                patterns.rows.get(row_count - 1).end;

            patterns.tokens.truncate(token_count);

            var class_end: u32 = 0;

            for (patterns.tokens.const_slice()) |token| {
                switch (token) {
                    .class => |held| class_end = @max(class_end, held.offset + glob.class_bytes),
                    .any, .literal, .segment_star, .star, .tail_star => {},
                }
            }

            patterns.classes.truncate(class_end);

            assert(patterns.rows.count() == row_count);
            assert(patterns.shapes.count() == row_count);
        }

        pub fn scratch_init(
            patterns: *const Patterns,
            gpa: std.mem.Allocator,
        ) std.mem.Allocator.Error!Scratch {
            assert(patterns.tokens.capacity() > 0);

            return Scratch.init(gpa, patterns.tokens.capacity());
        }

        fn anchor(
            patterns: *Patterns,
            pattern: []const u8,
            anchoring: Anchoring,
            capacity: u32,
        ) Error!void {
            assert(capacity > 0);
            assert(pattern.len <= glob.variant_bytes_max);

            const leading = pattern.len > 0 and pattern[0] == glob.separator;
            const rooted = leading or std.mem.startsWith(u8, pattern, "**/");

            const anchored = switch (anchoring) {
                .anchored => true,
                .inferred => std.mem.findScalar(u8, pattern, glob.separator) != null,
                .unanchored => false,
            };

            const bare = rooted or anchored;
            const prefix: []const u8 = if (bare) "" else "**/";

            try patterns.row_compiled(pattern, prefix, "", capacity);
            try patterns.row_compiled(pattern, prefix, "/**", capacity);
        }

        fn row_compiled(
            patterns: *Patterns,
            pattern: []const u8,
            prefix: []const u8,
            suffix: []const u8,
            capacity: u32,
        ) Error!void {
            assert(prefix.len <= 3);
            assert(suffix.len <= 3);
            assert(pattern.len <= std.math.maxInt(u32));

            const start = patterns.tokens.count();
            const runs = [_][]const u8{ prefix, pattern, suffix };

            for (runs) |run| {
                try glob.compile(run, &patterns.tokens, &patterns.classes, &patterns.diagnostic);
            }

            const end = patterns.tokens.count();
            if (end > capacity) return error.BytesExhausted;
            if (patterns.rows.full()) return error.PatternsExhausted;

            patterns.rows.push(.{ .end = end, .start = start });
        }

        fn row_matches(
            patterns: *const Patterns,
            scratch: *Scratch,
            row: Row,
            index: u32,
            subject: []const u8,
        ) bool {
            assert(index < patterns.rows.count());
            assert(row.end <= patterns.tokens.count());
            assert(subject.len <= std.math.maxInt(u32));

            const shape: Shape = if (index < patterns.shapes.count())
                patterns.shapes.get(index)
            else
                .general;

            const tokens = patterns.tokens.const_slice();
            const classes = patterns.classes.const_slice();
            if (Matcher.shaped(shape, tokens, classes, subject)) |answer| return answer;
            return Matcher.matches(row, tokens, classes, scratch, subject);
        }
    };
}

fn trimmed(pattern: []const u8) []const u8 {
    assert(pattern.len <= std.math.maxInt(u32));

    var held = pattern;

    for (0..pattern.len + 1) |_| {
        if (!std.mem.startsWith(u8, held, "./")) break;

        held = held[2..];
    }

    for (0..pattern.len + 1) |_| {
        if (!std.mem.endsWith(u8, held, "/")) break;

        held = held[0 .. held.len - 1];
    }

    assert(held.len <= pattern.len);

    return held;
}

const byte_count_max_test: u32 = 1_024;
const class_count_max_test: u32 = 32;
const pattern_count_max_test: u32 = 32;

const shapes_test = [_][]const u8{
    "venv",
    "*.db",
    "robit.log*",
    "dev_tool*.exe",
    "static_files/core",
    "docs/**",
    "*.py[cod]",
    "*.rs.bk",
    "page?.html",
    "[!x]env",
    "cache[0-9]/**",
    "dev_tool?v*.exe",
    "editors/vscode/*.vsix",
    "editors/*/out",
    "build/*",
    "static_files/core[0-9]/*.js",
    "a*b",
    "**/.claude/settings.local.json",
    "**/.claude/worktrees",
    "**/a/b",
    "**/a*/b",
    "**/x/*.js",
    "**/x/[0-9]?/y",
};

const paths_test = [_][]const u8{
    "",
    ".claude/settings.local.json",
    "deep/.claude/settings.local.json",
    "deep/.claude/settings.local.json/held",
    "x.claude/settings.local.json",
    "deep/.claude/settings.local.jsonx",
    ".claude/worktrees",
    ".claude/worktrees/",
    "deep/.claude/worktrees/one/two",
    "a/b",
    "a/b/",
    "a//b",
    "deep/a/b",
    "deep/a/b/c",
    "deep/ab/b",
    "deep/xa/b",
    "aa/b",
    "a/a/b",
    "b/a/b/a/b",
    "x/app.js",
    "deep/x/app.js",
    "deep/x/app.js/held",
    "x/deep/app.js",
    "deep/x/12/y",
    "deep/x/1/y",
    "x/1a/y/z",
    "venv",
    "venv/",
    "venv/page.html",
    "app/venv/deep/page.html",
    "venved/page.html",
    "a/venv",
    "app.db",
    "deep/app.db",
    "app.db/inside",
    "app.dbx",
    ".db",
    "robit.log",
    "robit.log.1",
    "deep/robit.log.1/held",
    "robit.lo",
    "dev_tool.exe",
    "dev_tool_v2.exe",
    "dev_tool.exes",
    "static_files/core",
    "static_files/core/js",
    "app/static_files/core",
    "docs",
    "docs/",
    "docs/guide.md",
    "docsx/guide.md",
    "app.pyc",
    "app.pyo",
    "app.pyd",
    "app.pye",
    "deep/app.pyc",
    "main.rs.bk",
    "page1.html",
    "page.html",
    "page12.html",
    "xenv/page.html",
    "cache7",
    "cache7/held",
    "cachex/held",
    "dev_tool_v2.exe",
    "dev_toolxv.exe",
    "editors/vscode/extension.vsix",
    "editors/vscode/extension.vsix/held",
    "editors/vscode/deep/extension.vsix",
    "editors/vscode/.vsix",
    "editors/intellij/out",
    "editors/intellij/out/held",
    "editors/out",
    "build/main.js",
    "build/deep/main.js",
    "build/",
    "static_files/core7/app.js",
    "static_files/core7/deep/app.js",
    "static_files/corex/app.js",
    "ab",
    "axb",
    "a/b",
    "axxb",
};

fn built(patterns: []const []const u8) !PatternsType(glob.platform_native) {
    assert(patterns.len <= std.math.maxInt(u32));

    return built_on(glob.platform_native, std.testing.allocator, patterns, .inferred);
}

fn built_on(
    comptime platform: path_platform.Platform,
    gpa: std.mem.Allocator,
    patterns: []const []const u8,
    anchoring: Anchoring,
) !PatternsType(platform) {
    assert(patterns.len <= std.math.maxInt(u32));

    var held: PatternsType(platform) = try .init(gpa, .{
        .byte_count_max = byte_count_max_test,
        .class_count_max = class_count_max_test,
        .pattern_count_max = pattern_count_max_test,
    });

    errdefer held.deinit(gpa);

    for (patterns) |pattern| {
        try held.push_anchoring(pattern, anchoring);
    }

    return held;
}

fn floating(patterns: []const []const u8) !PatternsType(glob.platform_native) {
    assert(patterns.len <= std.math.maxInt(u32));

    return built_on(glob.platform_native, std.testing.allocator, patterns, .unanchored);
}

fn reserved() !PatternsType(glob.platform_native) {
    return built_on(glob.platform_native, std.testing.allocator, &.{}, .inferred);
}

fn expect_windows_separator(comptime platform: path_platform.Platform) !void {
    const gpa = std.testing.allocator;
    const windows = platform == .windows;
    var patterns = try built_on(platform, gpa, &.{"*.rs"}, .inferred);
    defer patterns.deinit(gpa);

    var scratch = try patterns.scratch_init(gpa);
    defer scratch.deinit(gpa);

    var nested = try built_on(platform, gpa, &.{"src/*.rs"}, .inferred);
    defer nested.deinit(gpa);

    try std.testing.expect(patterns.matches(&scratch, "src\\main.rs"));
    try std.testing.expectEqual(windows, nested.matches(&scratch, "src\\main.rs"));
    try std.testing.expect(patterns.matches_walked(&scratch, "src\\main.rs"));
    try std.testing.expectEqual(windows, nested.matches_walked(&scratch, "src\\main.rs"));

    var anchored = try built_on(platform, gpa, &.{"*.rs"}, .anchored);
    defer anchored.deinit(gpa);

    try std.testing.expectEqual(windows, !anchored.matches(&scratch, "src\\main.rs"));
    try std.testing.expectEqual(windows, !anchored.matches_walked(&scratch, "src\\main.rs"));
}

test PatternsType {
    const gpa = std.testing.allocator;
    const Patterns = PatternsType(glob.platform_native);

    const capacity: Patterns.Capacity = .{
        .byte_count_max = 256,
        .class_count_max = 4,
        .pattern_count_max = 8,
    };

    var patterns: Patterns = try .init(gpa, capacity);
    defer patterns.deinit(gpa);

    var scratch = try patterns.scratch_init(gpa);
    defer scratch.deinit(gpa);

    try patterns.push("vendor");
    try patterns.push("*.{css,js}");
    try std.testing.expect(patterns.matches(&scratch, "app/vendor/page.html"));
    try std.testing.expect(patterns.matches(&scratch, "static/app.css"));
    try std.testing.expect(!patterns.matches(&scratch, "src/main.rs"));
    try std.testing.expectError(error.ClassUnclosed, patterns.push("templates/["));
    try std.testing.expectEqual(10, patterns.diagnostic.offset);
}

test "an empty set matches nothing" {
    var patterns = try reserved();
    defer patterns.deinit(std.testing.allocator);

    var scratch = try patterns.scratch_init(std.testing.allocator);
    defer scratch.deinit(std.testing.allocator);

    try std.testing.expect(patterns.empty());
    try std.testing.expect(!patterns.matches(&scratch, "templates/page.html"));
}

test "a bare name matches that directory at any depth" {
    var patterns = try built(&.{"vendor"});
    defer patterns.deinit(std.testing.allocator);

    var scratch = try patterns.scratch_init(std.testing.allocator);
    defer scratch.deinit(std.testing.allocator);

    try std.testing.expect(patterns.matches(&scratch, "vendor"));
    try std.testing.expect(patterns.matches(&scratch, "vendor/page.html"));
    try std.testing.expect(patterns.matches(&scratch, "app/vendor/deep/page.html"));
    try std.testing.expect(!patterns.matches(&scratch, "vendored/page.html"));
}

test "a trailing slash reads the same as the bare name" {
    var patterns = try built(&.{"vendor/"});
    defer patterns.deinit(std.testing.allocator);

    var scratch = try patterns.scratch_init(std.testing.allocator);
    defer scratch.deinit(std.testing.allocator);

    try std.testing.expect(patterns.matches(&scratch, "vendor/page.html"));
    try std.testing.expect(patterns.matches(&scratch, "app/vendor/page.html"));
    try std.testing.expect(!patterns.matches(&scratch, "vendored/page.html"));
}

test "a leading dot slash is cut before anything else" {
    var patterns = try built(&.{"./vendor"});
    defer patterns.deinit(std.testing.allocator);

    var scratch = try patterns.scratch_init(std.testing.allocator);
    defer scratch.deinit(std.testing.allocator);

    try std.testing.expect(patterns.matches(&scratch, "vendor/page.html"));
    try std.testing.expect(patterns.matches(&scratch, "app/vendor/page.html"));
}

test "a pattern holding a slash is anchored at the root" {
    var patterns = try built(&.{"app/vendor"});
    defer patterns.deinit(std.testing.allocator);

    var scratch = try patterns.scratch_init(std.testing.allocator);
    defer scratch.deinit(std.testing.allocator);

    try std.testing.expect(patterns.matches(&scratch, "app/vendor/page.html"));
    try std.testing.expect(!patterns.matches(&scratch, "site/app/vendor/page.html"));
}

test "an unanchored pattern holding a slash matches at any depth" {
    var patterns = try floating(&.{"tests/*"});
    defer patterns.deinit(std.testing.allocator);

    var scratch = try patterns.scratch_init(std.testing.allocator);
    defer scratch.deinit(std.testing.allocator);

    try std.testing.expect(patterns.matches(&scratch, "/home/work/tests/lint.rs"));
    try std.testing.expect(patterns.matches(&scratch, "tests/lint.rs"));
    try std.testing.expect(!patterns.matches(&scratch, "/home/work/src/lint.rs"));

    var rooted = try floating(&.{"/home/work/tests/*"});
    defer rooted.deinit(std.testing.allocator);

    try std.testing.expect(rooted.matches(&scratch, "/home/work/tests/lint.rs"));
    try std.testing.expect(!rooted.matches(&scratch, "/other/home/work/tests/lint.rs"));
}

test "an unanchored push matches a slashed pattern at any depth" {
    var patterns = try reserved();
    defer patterns.deinit(std.testing.allocator);

    var scratch = try patterns.scratch_init(std.testing.allocator);
    defer scratch.deinit(std.testing.allocator);

    try patterns.push_unanchored("tests/*");
    try std.testing.expect(patterns.matches(&scratch, "/home/work/tests/lint.rs"));
    try std.testing.expect(!patterns.matches(&scratch, "/home/work/src/lint.rs"));
}

test "an anchored pattern matches at the root alone" {
    var patterns = try reserved();
    defer patterns.deinit(std.testing.allocator);

    var scratch = try patterns.scratch_init(std.testing.allocator);
    defer scratch.deinit(std.testing.allocator);

    try patterns.push_anchored("vendor");

    try std.testing.expect(patterns.matches(&scratch, "vendor"));
    try std.testing.expect(patterns.matches(&scratch, "vendor/page.html"));
    try std.testing.expect(!patterns.matches(&scratch, "app/vendor"));
    try std.testing.expect(!patterns.matches(&scratch, "app/vendor/page.html"));
}

test "a star stops at a directory separator" {
    var patterns = try built(&.{"*.min.js"});
    defer patterns.deinit(std.testing.allocator);

    var scratch = try patterns.scratch_init(std.testing.allocator);
    defer scratch.deinit(std.testing.allocator);

    try std.testing.expect(patterns.matches(&scratch, "static/app.min.js"));
    try std.testing.expect(!patterns.matches(&scratch, "static/app.min.js.map"));
}

test "a double star pattern reaches through directories" {
    var patterns = try built(&.{"**/admin/*.html"});
    defer patterns.deinit(std.testing.allocator);

    var scratch = try patterns.scratch_init(std.testing.allocator);
    defer scratch.deinit(std.testing.allocator);

    try std.testing.expect(patterns.matches(&scratch, "templates/admin/list.html"));
    try std.testing.expect(patterns.matches(&scratch, "admin/list.html"));
    try std.testing.expect(!patterns.matches(&scratch, "templates/admin/deep/list.html"));
}

test "a trailing double star takes the rest of the path" {
    var patterns = try built(&.{"static/**"});
    defer patterns.deinit(std.testing.allocator);

    var scratch = try patterns.scratch_init(std.testing.allocator);
    defer scratch.deinit(std.testing.allocator);

    try std.testing.expect(patterns.matches(&scratch, "static/a.js"));
    try std.testing.expect(patterns.matches(&scratch, "static/deep/a.js"));
    try std.testing.expect(!patterns.matches(&scratch, "static"));
}

test "a question mark takes one byte that is not a separator" {
    var patterns = try built(&.{"page?.html"});
    defer patterns.deinit(std.testing.allocator);

    var scratch = try patterns.scratch_init(std.testing.allocator);
    defer scratch.deinit(std.testing.allocator);

    try std.testing.expect(patterns.matches(&scratch, "page1.html"));
    try std.testing.expect(!patterns.matches(&scratch, "page.html"));
    try std.testing.expect(!patterns.matches(&scratch, "page12.html"));
    try std.testing.expect(!patterns.matches(&scratch, "pag/e.html"));
}

test "a character class takes the bytes it names" {
    var patterns = try built(&.{"page[0-9].html"});
    defer patterns.deinit(std.testing.allocator);

    var scratch = try patterns.scratch_init(std.testing.allocator);
    defer scratch.deinit(std.testing.allocator);

    try std.testing.expect(patterns.matches(&scratch, "page7.html"));
    try std.testing.expect(!patterns.matches(&scratch, "pagex.html"));
}

test "a negated class takes every byte it does not name" {
    var patterns = try built(&.{"page[!0-9].html"});
    defer patterns.deinit(std.testing.allocator);

    var scratch = try patterns.scratch_init(std.testing.allocator);
    defer scratch.deinit(std.testing.allocator);

    try std.testing.expect(patterns.matches(&scratch, "pagex.html"));
    try std.testing.expect(!patterns.matches(&scratch, "page7.html"));
}

test "a caret negates a class the same way a bang does" {
    var patterns = try built(&.{"page[^0-9].html"});
    defer patterns.deinit(std.testing.allocator);

    var scratch = try patterns.scratch_init(std.testing.allocator);
    defer scratch.deinit(std.testing.allocator);

    try std.testing.expect(patterns.matches(&scratch, "pagex.html"));
    try std.testing.expect(!patterns.matches(&scratch, "page7.html"));
}

test "a class never takes a separator" {
    var patterns = try built(&.{"a[!x]b"});
    defer patterns.deinit(std.testing.allocator);

    var scratch = try patterns.scratch_init(std.testing.allocator);
    defer scratch.deinit(std.testing.allocator);

    try std.testing.expect(patterns.matches(&scratch, "a-b"));
    try std.testing.expect(!patterns.matches(&scratch, "a/b"));
}

test "an alternation stands for each of its branches" {
    var patterns = try built(&.{"*.{css,js}"});
    defer patterns.deinit(std.testing.allocator);

    var scratch = try patterns.scratch_init(std.testing.allocator);
    defer scratch.deinit(std.testing.allocator);

    try std.testing.expect(patterns.matches(&scratch, "static/app.css"));
    try std.testing.expect(patterns.matches(&scratch, "static/app.js"));
    try std.testing.expect(!patterns.matches(&scratch, "static/app.map"));
}

test "a nested alternation expands through every level" {
    var patterns = try built(&.{"a/{b,c/{d,e}}/f"});
    defer patterns.deinit(std.testing.allocator);

    var scratch = try patterns.scratch_init(std.testing.allocator);
    defer scratch.deinit(std.testing.allocator);

    try std.testing.expect(patterns.matches(&scratch, "a/b/f"));
    try std.testing.expect(patterns.matches(&scratch, "a/c/d/f"));
    try std.testing.expect(patterns.matches(&scratch, "a/c/e/f"));
    try std.testing.expect(!patterns.matches(&scratch, "a/c/f"));
}

test "an escaped metacharacter stands for itself" {
    var patterns = try built(&.{"a\\*b"});
    defer patterns.deinit(std.testing.allocator);

    var scratch = try patterns.scratch_init(std.testing.allocator);
    defer scratch.deinit(std.testing.allocator);

    try std.testing.expect(patterns.matches(&scratch, "a*b"));
    try std.testing.expect(!patterns.matches(&scratch, "axb"));
}

test "several patterns match as one set" {
    var patterns = try built(&.{ "vendor", "*.min.js", "**/admin/*.html" });
    defer patterns.deinit(std.testing.allocator);

    var scratch = try patterns.scratch_init(std.testing.allocator);
    defer scratch.deinit(std.testing.allocator);

    try std.testing.expect(patterns.matches(&scratch, "vendor/a.html"));
    try std.testing.expect(patterns.matches(&scratch, "static/a.min.js"));
    try std.testing.expect(patterns.matches(&scratch, "t/admin/list.html"));
    try std.testing.expect(!patterns.matches(&scratch, "t/page.html"));
}

test "the matched row names the pattern that covered the path" {
    var patterns = try built(&.{ "vendor", "static" });
    defer patterns.deinit(std.testing.allocator);

    var scratch = try patterns.scratch_init(std.testing.allocator);
    defer scratch.deinit(std.testing.allocator);

    const vendor = patterns.matched(&scratch, "vendor/a.html");
    const held = patterns.matched(&scratch, "static/a.js");

    try std.testing.expect(vendor != null);
    try std.testing.expect(held != null);
    try std.testing.expect(vendor.? != held.?);
    try std.testing.expect(patterns.matched(&scratch, "src/a.rs") == null);
}

test "a row range answers for the patterns it spans" {
    var patterns = try reserved();
    defer patterns.deinit(std.testing.allocator);

    var scratch = try patterns.scratch_init(std.testing.allocator);
    defer scratch.deinit(std.testing.allocator);

    try patterns.push("vendor");

    const start = patterns.count();

    try patterns.push("static");

    const end = patterns.count();
    const latter: Span = .between(start, end);
    const former: Span = .between(0, start);

    try std.testing.expect(patterns.matches_within(&scratch, latter, "static/a.js"));
    try std.testing.expect(!patterns.matches_within(&scratch, latter, "vendor/a.html"));
    try std.testing.expect(patterns.matches_within(&scratch, former, "vendor/a.html"));
}

test "a truncated set forgets the rows past the mark" {
    var patterns = try reserved();
    defer patterns.deinit(std.testing.allocator);

    var scratch = try patterns.scratch_init(std.testing.allocator);
    defer scratch.deinit(std.testing.allocator);

    try patterns.push("vendor");

    const mark = patterns.count();
    const token_count = patterns.tokens.count();

    try patterns.push("page[0-9].html");
    try std.testing.expect(patterns.matches(&scratch, "page7.html"));
    try std.testing.expect(patterns.classes.count() > 0);

    patterns.truncate(mark);

    try std.testing.expectEqual(mark, patterns.count());
    try std.testing.expectEqual(token_count, patterns.tokens.count());
    try std.testing.expectEqual(0, patterns.classes.count());
    try std.testing.expect(patterns.matches(&scratch, "vendor/a.html"));
    try std.testing.expect(!patterns.matches(&scratch, "page7.html"));

    try patterns.push("page[0-9].html");
    try std.testing.expect(patterns.matches(&scratch, "page7.html"));
}

test "an empty pattern is refused" {
    var patterns = try reserved();
    defer patterns.deinit(std.testing.allocator);

    try std.testing.expectError(error.Empty, patterns.push(""));
    try std.testing.expectError(error.Empty, patterns.push("./"));
    try std.testing.expectError(error.Empty, patterns.push("///"));
}

test "an unclosed class names where it opened" {
    var patterns = try reserved();
    defer patterns.deinit(std.testing.allocator);

    const refused = patterns.push("templates/[");

    try std.testing.expectError(error.ClassUnclosed, refused);
    try std.testing.expectEqual(10, patterns.diagnostic.offset);

    refused catch |err| {
        try std.testing.expect(std.mem.find(u8, glob.message(err), "character class") != null);
    };
}

test "an unclosed brace is refused" {
    var patterns = try reserved();
    defer patterns.deinit(std.testing.allocator);

    try std.testing.expectError(error.BraceUnclosed, patterns.push("a/{b,c"));
}

test "a trailing backslash is refused" {
    var patterns = try reserved();
    defer patterns.deinit(std.testing.allocator);

    try std.testing.expectError(error.EscapeUnfinished, patterns.push("a\\"));
}

test "a double star that is not a whole component is refused" {
    var patterns = try reserved();
    defer patterns.deinit(std.testing.allocator);

    try std.testing.expectError(error.DoubleStarComponent, patterns.push("a/b**c"));
}

test "a set that outgrows its tables says so" {
    var patterns: PatternsType(glob.platform_native) = try .init(std.testing.allocator, .{
        .byte_count_max = 16,
        .class_count_max = 1,
        .pattern_count_max = 2,
    });

    defer patterns.deinit(std.testing.allocator);

    var refused: ?Error = null;

    for (0..64) |_| {
        patterns.push("templates/deeply/nested/name") catch |err| {
            refused = err;

            break;
        };
    }

    try std.testing.expectEqual(@as(?Error, error.BytesExhausted), refused);
}

test "a set out of rows names the patterns table" {
    var patterns: PatternsType(glob.platform_native) = try .init(std.testing.allocator, .{
        .byte_count_max = 1_024,
        .class_count_max = 1,
        .pattern_count_max = 1,
    });

    defer patterns.deinit(std.testing.allocator);

    try patterns.push("a");
    try patterns.push("b");
    try patterns.push("c");
    try patterns.push("d");
    try std.testing.expectError(error.PatternsExhausted, patterns.push("e"));
    try std.testing.expectError(error.ClassesExhausted, patterns.push("[ab]/[cd]"));
}

test "a pathological pattern still answers in one pass" {
    var patterns = try built(&.{"**/*a*/**/*b*/**/*c*"});
    defer patterns.deinit(std.testing.allocator);

    var scratch = try patterns.scratch_init(std.testing.allocator);
    defer scratch.deinit(std.testing.allocator);

    const subject = "a/aaaa/aaaa/aaaa/aaaa/aaaa/aaaa/aaaa/aaaa/aaaa/aaaa/aaaa/aaaa/aaaa";

    try std.testing.expect(!patterns.matches(&scratch, subject));
}

test "matching allocates nothing" {
    var static_allocator: StaticAllocator = .init(std.testing.allocator);
    defer static_allocator.deinit();

    var patterns = try built_on(
        glob.platform_native,
        static_allocator.allocator(),
        &.{ "vendor", "**/admin/*.html", "*.{css,js}" },
        .inferred,
    );

    defer patterns.deinit(static_allocator.allocator());

    var scratch = try patterns.scratch_init(static_allocator.allocator());
    defer scratch.deinit(static_allocator.allocator());

    static_allocator.transition_from_init_to_static();
    defer static_allocator.transition_from_static_to_deinit();

    try std.testing.expect(patterns.matches(&scratch, "app/vendor/page.html"));
    try std.testing.expect(patterns.matches(&scratch, "t/admin/list.html"));
    try std.testing.expect(patterns.matches(&scratch, "static/app.css"));
    try std.testing.expect(!patterns.matches(&scratch, "src/main.rs"));
}

test "a windows separator bounds a component only on windows" {
    try expect_windows_separator(.posix);
    try expect_windows_separator(.windows);
}

test "a shaped row answers the same as the walk" {
    for (shapes_test) |shape| {
        var patterns = try built(&.{shape});
        defer patterns.deinit(std.testing.allocator);

        var scratch = try patterns.scratch_init(std.testing.allocator);
        defer scratch.deinit(std.testing.allocator);

        for (paths_test) |subject| {
            const walked = patterns.matches_walked(&scratch, subject);

            try std.testing.expectEqual(patterns.matches(&scratch, subject), walked);
        }
    }
}

test "a leading double star matches whole components only" {
    var patterns = try built(&.{ "**/.claude/worktrees", "**/**/cache/*.db" });
    defer patterns.deinit(std.testing.allocator);

    var scratch = try patterns.scratch_init(std.testing.allocator);
    defer scratch.deinit(std.testing.allocator);

    try std.testing.expect(patterns.matches_walked(&scratch, ".claude/worktrees"));
    try std.testing.expect(patterns.matches_walked(&scratch, "deep/.claude/worktrees/one"));
    try std.testing.expect(patterns.matches_walked(&scratch, "cache/app.db"));
    try std.testing.expect(patterns.matches_walked(&scratch, "a/b/cache/app.db"));
    try std.testing.expect(!patterns.matches_walked(&scratch, "x.claude/worktrees"));
    try std.testing.expect(!patterns.matches_walked(&scratch, "deep/x.claude/worktrees"));
    try std.testing.expect(!patterns.matches_walked(&scratch, "a/xcache/app.db"));
}
