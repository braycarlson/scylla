const std = @import("std");
const assert = std.debug.assert;
const Buffer = @import("../stdx/bounded/buffer.zig");
const Formatters = @import("../format.zig").Formatters;
const FrontCapacity = @import("../syntax/front.zig").Front.Capacity;
const Language = @import("../syntax/language.zig").Language;
const fuzz = @import("../testing/fuzz.zig");

const atoms = [_][]const u8{
    "(",      ")",     "{",    "}",    "[",     "]",      ",",      ";",   ":",    ".",
    "=",      "+",     "-",    "*",    "/",     "<",      ">",      "!",   "?",    "&",
    "|",      "\"a\"", "'a'",  "x",    "1",     " ",      "\n",     "=>",  "->",   "::",
    "..",     "@",     "#",    "$",    "`",     "\\",     "fn",     "if",  "else", "return",
    "def",    "class", "func", "let",  "const", "struct", "import", "for", "in",   "match",
    "switch", "async", "proc", "type", "impl",  "pub",    ":=",     "%",
};

const languages = [_]Language{
    .css,
    .go,
    .javascript,
    .odin,
    .python,
    .rust,
    .typescript,
    .zig,
};

const front_capacity: FrontCapacity = .{
    .diagnostic_count_max = 1 << 8,
    .event_count_max = 1 << 14,
    .node_count_max = 1 << 12,
    .semantic = null,
    .tag_count_max = 1 << 8,
    .token_count_max = 1 << 12,
};

const format_capacity: Formatters.Capacity = .{
    .arena_bytes_max = 1 << 18,
    .element_count_max = 1 << 14,
    .front = front_capacity,
    .line_count_max = 1 << 10,
    .pragma_count_max = 1 << 6,
};

const atom_bytes_max = 8;
const go_prefix = "package p\n";
const out_bytes_max: u32 = 1 << 16;
const radix: u64 = atoms.len + 1;
const sequence_atoms = 3;
const sequence_count: u64 = radix * radix * radix;
const source_bytes_max = go_prefix.len + sequence_atoms * atom_bytes_max;
const stride: u64 = 7_919;

comptime {
    assert(std.math.gcd(stride, sequence_count) == 1);
    assert(sequence_count < std.math.maxInt(u32));

    for (atoms) |atom| {
        assert(atom.len > 0);
        assert(atom.len <= atom_bytes_max);
    }
}

pub fn main(gpa: std.mem.Allocator, args: fuzz.Arguments) !void {
    if (args.events_max) |events_max| assert(events_max > 0);

    const start = args.seed % sequence_count;
    const count = @min(args.events_max orelse sequence_count, sequence_count);
    var first: Buffer = try .init(gpa, out_bytes_max);
    defer first.deinit(gpa);

    var second: Buffer = try .init(gpa, out_bytes_max);
    defer second.deinit(gpa);

    for (languages) |language| {
        const formatters = try gpa.create(Formatters);
        defer gpa.destroy(formatters);

        try formatters.init(gpa, &format_capacity, .initOne(language), &.{});
        defer formatters.deinit(gpa);

        sweep(formatters, language, .{ .count = count, .start = start }, &first, &second);
    }
}

fn sweep(
    formatters: *Formatters,
    language: Language,
    window: struct { count: u64, start: u64 },
    first: *Buffer,
    second: *Buffer,
) void {
    assert(window.count <= sequence_count);
    assert(window.start < sequence_count);
    assert(language.lexes());

    var buffer: [source_bytes_max]u8 = undefined;

    for (0..window.count) |step| {
        const index = (window.start + step * stride) % sequence_count;
        const source = sequence_of(language, index, &buffer);

        check(formatters, language, source, first, second);
    }
}

fn sequence_of(language: Language, index: u64, buffer: *[source_bytes_max]u8) []const u8 {
    assert(index < sequence_count);
    assert(language.lexes());

    const prefix: []const u8 = if (language == .go) go_prefix else "";

    const picks = [sequence_atoms]u64{
        index / (radix * radix),
        (index / radix) % radix,
        index % radix,
    };

    var length: usize = prefix.len;

    @memcpy(buffer[0..prefix.len], prefix);

    for (picks) |pick| {
        if (pick == atoms.len) continue;

        @memcpy(buffer[length..][0..atoms[pick].len], atoms[pick]);
        length += atoms[pick].len;
    }

    assert(length <= source_bytes_max);

    return buffer[0..length];
}

fn check(
    formatters: *Formatters,
    language: Language,
    source: []const u8,
    first: *Buffer,
    second: *Buffer,
) void {
    assert(source.len <= std.math.maxInt(u32));
    assert(language.lexes());

    first.clear();

    formatters.format(.of(language), source, first) catch return;

    second.clear();

    const once = first.const_slice();

    formatters.format(.of(language), once, second) catch |err| {
        std.debug.panic("{t}: \"{f}\" formats to \"{f}\", which fails with {t}", .{
            language,
            std.zig.fmtString(source),
            std.zig.fmtString(once),
            err,
        });
    };

    if (!std.mem.eql(u8, once, second.const_slice())) {
        std.debug.panic("{t}: \"{f}\" formats to \"{f}\", then to \"{f}\"", .{
            language,
            std.zig.fmtString(source),
            std.zig.fmtString(once),
            std.zig.fmtString(second.const_slice()),
        });
    }
}

test "a strided sweep formats every language to a fixed point" {
    try main(std.testing.allocator, .{ .seed = 0, .events_max = 256 });
}
