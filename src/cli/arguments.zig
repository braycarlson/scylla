const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const bounded = @import("../stdx/bounded.zig");
const path_of = @import("../platform/path.zig").path_of;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const expectEqualDeep = std.testing.expectEqualDeep;
const expectEqualStrings = std.testing.expectEqualStrings;
const expectError = std.testing.expectError;
const StaticAllocator = @import("../stdx/static_allocator.zig");
const path_platform = @import("../platform/path/platform.zig");
const Arguments = @This();

body: []u8,
command_line: []u8,
literal: bool,
message_buffer: [message_bytes_max]u8,
message_length: u32,
remaining: u32,
scratch: Words,
words: Words,

pub const Capacity = struct {
    argfile_bytes_max: u32,
    word_bytes_max: u32,
    word_count_max: u32,
};

pub const CapacityError = error{
    ArgfileExhausted,
    CommandLineExhausted,
    TargetExhausted,
    TextExhausted,
    WordsExhausted,
};

pub const Error = CapacityError || InputError;
pub const InputError = error{NotText};

pub const Usage = struct {
    message: []const u8,
    text: []const u8,
};

pub const UsageError = error{ValueMissing};

pub const Word = union(enum) {
    option: Option,
    positional: []const u8,

    pub const Option = struct {
        name: []const u8,
        value: ?[]const u8,
    };
};

pub const Words = struct {
    bytes: bounded.Buffer,
    spans: bounded.ArrayType(Span),

    pub const Span = struct {
        end: u32,
        start: u32,
    };

    pub fn init(gpa: std.mem.Allocator, capacity: Capacity) std.mem.Allocator.Error!Words {
        assert(capacity.word_bytes_max > 0);
        assert(capacity.word_count_max > 0);

        var bytes = try bounded.Buffer.init(gpa, capacity.word_bytes_max);
        errdefer bytes.deinit(gpa);

        const spans = try bounded.ArrayType(Span).init(gpa, capacity.word_count_max);
        return .{ .bytes = bytes, .spans = spans };
    }

    pub fn deinit(words: *Words, gpa: std.mem.Allocator) void {
        assert(words.spans.count() <= words.spans.capacity());
        assert(words.bytes.count() <= words.bytes.capacity());

        words.spans.deinit(gpa);
        words.bytes.deinit(gpa);
        words.* = undefined;
    }

    pub fn at(words: *const Words, index: u32) []const u8 {
        assert(index < words.spans.count());

        const span = words.spans.get(index);

        assert(span.start <= span.end);
        assert(span.end <= words.bytes.count());

        return words.bytes.const_slice()[span.start..span.end];
    }

    pub fn clear(words: *Words) void {
        words.bytes.clear();
        words.spans.clear();
        assert(words.bytes.empty());
        assert(words.spans.empty());
    }

    pub fn count(words: *const Words) u32 {
        const word_count = words.spans.count();

        assert(word_count <= words.spans.capacity());

        return word_count;
    }

    pub fn push(words: *Words, word: []const u8) CapacityError!void {
        if (words.spans.full()) return error.WordsExhausted;
        assert(word.len <= std.math.maxInt(u32));

        const start = words.bytes.count();

        words.bytes.push(word) catch |err| switch (err) {
            error.Overflow => return error.TextExhausted,
        };

        words.spans.push(.{ .end = words.bytes.count(), .start = start });
        assert(words.bytes.count() - start == word.len);
        assert(words.spans.count() <= words.spans.capacity());
    }
};

const Argfile = union(enum) {
    body: []const u8,
    verbatim,
};

const argfile_depth_max: u32 = 8;
const argfile_prefix: u8 = '@';
const command_line_bytes_max: u32 = if (windows) command_line_units_max * 3 + 1 else 0;
const command_line_units_max: u32 = 32_767;
const exit_usage: u8 = 2;
const message_bytes_max: u32 = 256;
const whitespace = " \t\n\r\x0b\x0c";
const windows = builtin.target.os.tag == .windows;

pub fn init(gpa: std.mem.Allocator, capacity: Capacity) std.mem.Allocator.Error!Arguments {
    assert(capacity.argfile_bytes_max > 0);
    assert(capacity.word_count_max > 0);

    var words = try Words.init(gpa, capacity);
    errdefer words.deinit(gpa);

    var scratch = try Words.init(gpa, capacity);
    errdefer scratch.deinit(gpa);

    const body = try StaticAllocator.reserve(u8, gpa, capacity.argfile_bytes_max);
    errdefer StaticAllocator.release(u8, gpa, body);

    const command_line: []u8 = if (windows)
        try StaticAllocator.reserve(u8, gpa, command_line_bytes_max)
    else
        &.{};

    assert(command_line.len == command_line_bytes_max);

    return .{
        .body = body,
        .command_line = command_line,
        .literal = false,
        .message_buffer = undefined,
        .message_length = 0,
        .remaining = 0,
        .scratch = scratch,
        .words = words,
    };
}

pub fn deinit(arguments: *Arguments, gpa: std.mem.Allocator) void {
    assert(arguments.remaining <= arguments.words.count());
    assert(arguments.body.len > 0);

    if (windows) StaticAllocator.release(u8, gpa, arguments.command_line);

    StaticAllocator.release(u8, gpa, arguments.body);
    arguments.scratch.deinit(gpa);
    arguments.words.deinit(gpa);
    arguments.* = undefined;
}

pub fn load(arguments: *Arguments, io: std.Io, args: std.process.Args) Error!void {
    assert(arguments.command_line.len == command_line_bytes_max);
    assert(args.vector.len > 0);

    arguments.reset();

    var decoded: std.heap.FixedBufferAllocator = .init(arguments.command_line);

    var held = args.iterateAllocator(decoded.allocator()) catch {
        return error.CommandLineExhausted;
    };

    defer held.deinit();

    _ = held.skip();

    while (held.next()) |argument| {
        assert(arguments.words.count() <= arguments.words.spans.capacity());

        try arguments.words.push(argument);
    }

    try arguments.expand_argfiles(io);
    try arguments.load_checked();
    assert(arguments.remaining == arguments.words.count());
}

pub fn load_words(arguments: *Arguments, io: std.Io, given: []const []const u8) Error!void {
    assert(given.len <= std.math.maxInt(u32));

    try arguments.expand(io, given);
    try arguments.load_checked();
    assert(arguments.remaining == arguments.words.count());
    assert(!arguments.literal);
}

fn expand(arguments: *Arguments, io: std.Io, given: []const []const u8) CapacityError!void {
    assert(given.len <= std.math.maxInt(u32));

    arguments.reset();

    for (given) |argument| {
        try arguments.words.push(argument);
    }

    assert(arguments.words.count() == given.len);

    try arguments.expand_argfiles(io);
}

pub fn at(arguments: *const Arguments, word_index: u32) []const u8 {
    assert(word_index < arguments.words.count());
    assert(arguments.remaining <= arguments.words.count());

    return arguments.words.at(word_index);
}

pub fn consumed_count(arguments: *const Arguments) u32 {
    const word_count = arguments.words.count();

    assert(arguments.remaining <= word_count);
    assert(word_count <= arguments.words.spans.capacity());

    return word_count - arguments.remaining;
}

pub fn count(arguments: *const Arguments) u32 {
    assert(arguments.remaining <= arguments.words.count());
    assert(arguments.words.count() <= arguments.words.spans.capacity());

    return arguments.words.count();
}

pub fn next(arguments: *Arguments) ?Word {
    if (arguments.remaining == 0) return null;

    var word = arguments.word_taken();

    if (!arguments.literal) {
        if (std.mem.eql(u8, word, "--")) {
            arguments.literal = true;

            if (arguments.remaining == 0) return null;

            word = arguments.word_taken();
        }
    }

    assert(arguments.remaining <= arguments.words.count());

    return word_of(word, arguments.literal);
}

pub fn next_raw(arguments: *Arguments) ?[]const u8 {
    assert(arguments.remaining <= arguments.words.count());

    if (arguments.remaining == 0) return null;
    return arguments.word_taken();
}

pub fn value(
    arguments: *Arguments,
    name: []const u8,
    attached: ?[]const u8,
) UsageError![]const u8 {
    assert(name.len > 0);
    assert(arguments.remaining <= arguments.words.count());
    if (attached) |held| assert(held.len <= std.math.maxInt(u32));

    if (attached) |held| return held;

    if (arguments.remaining == 0) {
        arguments.message_missing(name);

        return error.ValueMissing;
    }

    return arguments.word_taken();
}

fn word_taken(arguments: *Arguments) []const u8 {
    assert(arguments.remaining > 0);
    assert(arguments.remaining <= arguments.words.count());

    const word = arguments.words.at(arguments.consumed_count());

    arguments.remaining -= 1;

    return word;
}

pub fn message(arguments: *const Arguments) []const u8 {
    assert(arguments.message_length <= message_bytes_max);

    return arguments.message_buffer[0..arguments.message_length];
}

pub fn boolean_of(text: []const u8) ?bool {
    assert(text.len <= std.math.maxInt(u32));

    const truths = [_][]const u8{ "true", "yes", "1" };
    const falsehoods = [_][]const u8{ "false", "no", "0" };

    comptime assert(truths.len == falsehoods.len);

    for (truths) |spelling| {
        if (std.mem.eql(u8, text, spelling)) return true;
    }

    for (falsehoods) |spelling| {
        if (std.mem.eql(u8, text, spelling)) return false;
    }

    return null;
}

pub fn split_into(target: *bounded.ArrayType([]const u8), text: []const u8) CapacityError!void {
    assert(text.len <= std.math.maxInt(u32));

    var items = std.mem.splitScalar(u8, text, ',');
    var item_count: u32 = 0;

    while (items.next()) |item| {
        item_count += 1;

        assert(item_count <= text.len + 1);

        const trimmed = std.mem.trim(u8, item, whitespace);
        if (trimmed.len == 0) continue;
        if (target.full()) return error.TargetExhausted;

        target.push(trimmed);
    }

    assert(target.count() <= target.capacity());
}

pub fn usage_exit(usage: *const Usage) noreturn {
    assert(usage.message.len > 0);
    assert(usage.text.len > 0);

    var buffer: [64]u8 = undefined;
    const stderr = std.debug.lockStderr(&buffer);

    usage_write(&stderr.file_writer.interface, usage.text, usage.message) catch |err| switch (err) {
        error.WriteFailed => {
            std.debug.unlockStderr();
            std.process.exit(exit_usage);
        },
    };

    std.debug.unlockStderr();
    std.process.exit(exit_usage);
}

fn is_argfile(argument: []const u8) bool {
    if (argument.len <= 1) return false;
    if (!std.unicode.utf8ValidateSlice(argument)) return false;

    assert(argument.len > 1);

    return argument[0] == argfile_prefix;
}

fn usage_write(writer: *std.Io.Writer, usage: []const u8, text: []const u8) !void {
    assert(usage.len > 0);
    assert(text.len > 0);

    try writer.writeAll("error: ");
    try writer.writeAll(text);
    try writer.writeAll("\n\n");
    try writer.writeAll(usage);
    try writer.flush();
}

fn reset(arguments: *Arguments) void {
    arguments.literal = false;
    arguments.message_length = 0;
    arguments.remaining = 0;

    arguments.words.clear();
    arguments.scratch.clear();
    assert(arguments.words.count() == 0);
    assert(arguments.scratch.count() == 0);
}

fn load_checked(arguments: *Arguments) InputError!void {
    assert(arguments.remaining == 0);

    for (0..arguments.words.count()) |index| {
        const word = arguments.words.at(@intCast(index));

        if (!std.unicode.utf8ValidateSlice(word)) {
            arguments.message_set("an argument is not valid UTF-8");

            return error.NotText;
        }
    }

    assert(arguments.message_length == 0);

    arguments.remaining = arguments.words.count();
}

fn expand_argfiles(arguments: *Arguments, io: std.Io) CapacityError!void {
    assert(arguments.scratch.count() == 0);

    for (0..argfile_depth_max) |_| {
        const expanded_any = try arguments.expand_pass(io);
        if (!expanded_any) return;

        std.mem.swap(Words, &arguments.words, &arguments.scratch);
    }

    assert(arguments.words.count() <= arguments.words.spans.capacity());
}

fn expand_pass(arguments: *Arguments, io: std.Io) CapacityError!bool {
    var expanded_any = false;

    arguments.scratch.clear();

    for (0..arguments.words.count()) |index| {
        const argument = arguments.words.at(@intCast(index));

        switch (try argfile_read(io, argument, arguments.body)) {
            .verbatim => try arguments.scratch.push(argument),
            .body => |body| {
                expanded_any = true;

                try argfile_push_lines(&arguments.scratch, body);
            },
        }
    }

    if (!expanded_any) assert(arguments.scratch.count() == arguments.words.count());

    return expanded_any;
}

fn argfile_read(io: std.Io, argument: []const u8, buffer: []u8) CapacityError!Argfile {
    assert(buffer.len > 0);
    assert(argument.len <= std.math.maxInt(u32));

    if (!is_argfile(argument)) return .verbatim;

    const file_path = path_of(argument[1..]) orelse return .verbatim;
    const body = std.Io.Dir.cwd().readFile(io, file_path, buffer) catch return .verbatim;
    if (body.len == buffer.len) return error.ArgfileExhausted;
    if (!std.unicode.utf8ValidateSlice(body)) return .verbatim;

    assert(body.len < buffer.len);

    return .{ .body = body };
}

fn argfile_push_lines(words: *Words, body: []const u8) CapacityError!void {
    assert(body.len <= std.math.maxInt(u32));

    var lines = std.mem.splitScalar(u8, body, '\n');
    var line_count: u32 = 0;

    while (lines.next()) |line| {
        line_count += 1;

        assert(line_count <= body.len + 1);

        const trimmed = std.mem.trimEnd(u8, line, whitespace);
        if (trimmed.len == 0) continue;

        try words.push(trimmed);
    }
}

fn message_missing(arguments: *Arguments, name: []const u8) void {
    assert(name.len > 0);

    const written = std.mem.print(
        &arguments.message_buffer,
        "a value is required for '{s}' but none was supplied",
        .{name},
    ) catch arguments.message_buffer[0..];

    arguments.message_length = @intCast(written.len);

    assert(arguments.message_length <= message_bytes_max);
}

fn message_set(arguments: *Arguments, text: []const u8) void {
    assert(text.len <= message_bytes_max);

    @memcpy(arguments.message_buffer[0..text.len], text);
    arguments.message_length = @intCast(text.len);

    assert(arguments.message_length > 0);
}

fn word_of(word: []const u8, literal: bool) Word {
    assert(word.len <= std.math.maxInt(u32));

    if (literal) return .{ .positional = word };
    if (!std.mem.startsWith(u8, word, "-")) return .{ .positional = word };
    if (std.mem.eql(u8, word, "-")) return .{ .positional = word };

    assert(word.len > 1);

    assert(word[0] == '-');

    if (std.mem.findScalar(u8, word, '=')) |equals| {
        return .{ .option = .{ .name = word[0..equals], .value = word[equals + 1 ..] } };
    }

    return .{ .option = .{ .name = word, .value = null } };
}

const capacity_test: Capacity = .{
    .argfile_bytes_max = 1 << 10,
    .word_bytes_max = 1 << 10,
    .word_count_max = 32,
};

fn arguments_test(words: []const []const u8) !Arguments {
    assert(words.len <= std.math.maxInt(u32));

    var held = try Arguments.init(std.testing.allocator, capacity_test);
    errdefer held.deinit(std.testing.allocator);

    try held.load_words(std.testing.io, words);

    return held;
}

fn option_test(name: []const u8, attached: ?[]const u8) ?Word {
    assert(name.len <= std.math.maxInt(u32));
    if (attached) |held| assert(held.len <= std.math.maxInt(u32));

    return .{ .option = .{ .name = name, .value = attached } };
}

fn positional_test(text: []const u8) ?Word {
    assert(text.len <= std.math.maxInt(u32));

    return .{ .positional = text };
}

fn expect_words(expected: []const []const u8, words: *const Words) !void {
    try expectEqual(expected.len, words.count());

    for (expected, 0..) |word, index| {
        try expectEqualStrings(word, words.at(@intCast(index)));
    }
}

test Arguments {
    const gpa = std.testing.allocator;

    var arguments: Arguments = try .init(gpa, .{
        .argfile_bytes_max = 1 << 10,
        .word_bytes_max = 1 << 10,
        .word_count_max = 8,
    });

    defer arguments.deinit(gpa);

    try arguments.load_words(std.testing.io, &.{ "check", "--select=TS", "src" });

    const command = arguments.next() orelse return error.TestUnexpectedResult;
    const select = arguments.next() orelse return error.TestUnexpectedResult;
    const operand = arguments.next_raw() orelse return error.TestUnexpectedResult;
    const past = arguments.next();

    try std.testing.expectEqualStrings("check", command.positional);
    try std.testing.expectEqualStrings("--select", select.option.name);
    try std.testing.expectEqualStrings("TS", select.option.value.?);
    try std.testing.expectEqualStrings("src", operand);
    try std.testing.expect(past == null);
    try std.testing.expectEqual(@as(u32, 3), arguments.consumed_count());
}

test "a command line yields its words in order" {
    var held = try arguments_test(&.{
        "check",
        "--fix",
        "--select",
        "GL,HS",
        "--format=json",
        "a",
    });

    defer held.deinit(std.testing.allocator);

    const check = held.next();
    const fix = held.next();
    const select = held.next();
    const selected = try held.value("--select", null);
    const format = held.next();
    const formatted = try held.value("--format", "json");
    const positional = held.next();
    const past = held.next();

    try expectEqual(6, held.count());
    try expectEqual(6, held.consumed_count());
    try expectEqual(0, held.remaining);
    try expectEqualDeep(positional_test("check"), check);
    try expectEqualDeep(option_test("--fix", null), fix);
    try expectEqualDeep(option_test("--select", null), select);
    try expectEqualStrings("GL,HS", selected);
    try expectEqualDeep(option_test("--format", "json"), format);
    try expectEqualStrings("json", formatted);
    try expectEqualDeep(positional_test("a"), positional);
    try expectEqualDeep(null, past);
}

test "a dash is a positional and a double dash ends the options" {
    var held = try arguments_test(&.{ "-", "--", "--not-a-flag", "-x" });
    defer held.deinit(std.testing.allocator);

    const dash = held.next();
    const flag = held.next();
    const short = held.next();
    const past = held.next();

    try expectEqualDeep(positional_test("-"), dash);
    try expectEqualDeep(positional_test("--not-a-flag"), flag);
    try expectEqualDeep(positional_test("-x"), short);
    try expectEqualDeep(null, past);
}

test "a value at the end of the line is refused" {
    var held = try arguments_test(&.{"--select"});
    defer held.deinit(std.testing.allocator);

    const select = held.next();
    const missing = held.value("--select", null);

    try expectEqualDeep(option_test("--select", null), select);
    try expectError(error.ValueMissing, missing);
    try expect(std.mem.find(u8, held.message(), "--select") != null);
}

test "a short option is an option" {
    var held = try arguments_test(&.{ "-q", "-o=out.txt" });
    defer held.deinit(std.testing.allocator);

    const quiet = held.next();
    const output = held.next();

    try expectEqualDeep(option_test("-q", null), quiet);
    try expectEqualDeep(option_test("-o", "out.txt"), output);
}

test "a boolean word reads its three spellings" {
    try expectEqual(true, boolean_of("true"));
    try expectEqual(true, boolean_of("yes"));
    try expectEqual(true, boolean_of("1"));
    try expectEqual(false, boolean_of("false"));
    try expectEqual(false, boolean_of("no"));
    try expectEqual(false, boolean_of("0"));
    try expectEqual(null, boolean_of("maybe"));
    try expectEqual(null, boolean_of(""));
}

test "a list value splits on commas and drops blanks" {
    var target = try bounded.ArrayType([]const u8).init(std.testing.allocator, 8);
    defer target.deinit(std.testing.allocator);

    try split_into(&target, " GL, HS,,AL ");

    try expectEqual(3, target.count());
    try expectEqualStrings("GL", target.get(0));
    try expectEqualStrings("HS", target.get(1));
    try expectEqualStrings("AL", target.get(2));
}

test "an argfile expands one argument per line" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "args", .data = "check\n--fix\n\n.\n" });

    var argument_buffer: [path_platform.path_bytes_max]u8 = undefined;

    const argument = try std.mem.print(
        &argument_buffer,
        "@.zig-cache/tmp/{s}/args",
        .{&tmp.sub_path},
    );

    var held = try Arguments.init(std.testing.allocator, capacity_test);
    defer held.deinit(std.testing.allocator);

    try held.expand(io, &.{argument});
    try expect_words(&.{ "check", "--fix", "." }, &held.words);
    try held.load_words(io, &.{argument});

    const check = held.next();
    const fix = held.next();

    try expectEqualDeep(positional_test("check"), check);
    try expectEqualDeep(option_test("--fix", null), fix);
}

test "an unreadable argfile stays verbatim" {
    var held = try Arguments.init(std.testing.allocator, capacity_test);
    defer held.deinit(std.testing.allocator);

    try held.expand(std.testing.io, &.{"@/nonexistent/scylla-args"});
    try expect_words(&.{"@/nonexistent/scylla-args"}, &held.words);
}

test "a bare at sign is not an argfile" {
    var held = try Arguments.init(std.testing.allocator, capacity_test);
    defer held.deinit(std.testing.allocator);

    try held.expand(std.testing.io, &.{"@"});
    try expect_words(&.{"@"}, &held.words);
}

test "the process arguments load the same words on each platform" {
    var held = try Arguments.init(std.testing.allocator, capacity_test);
    defer held.deinit(std.testing.allocator);

    const line = "tool.exe --select \"ALL rules\" C:\\work\\a.py";

    const args: std.process.Args = if (windows)
        .{ .vector = std.unicode.utf8ToUtf16LeStringLiteral(line) }
    else
        .{ .vector = &.{ "tool.exe", "--select", "ALL rules", "C:\\work\\a.py" } };

    try held.load(std.testing.io, args);
    try expect_words(&.{ "--select", "ALL rules", "C:\\work\\a.py" }, &held.words);
    try expectEqualStrings("ALL rules", held.at(1));
}

test "an argument that is not text is refused" {
    var held = try Arguments.init(std.testing.allocator, capacity_test);
    defer held.deinit(std.testing.allocator);

    try expectError(error.NotText, held.load_words(std.testing.io, &.{"\xff\xfe"}));
}
