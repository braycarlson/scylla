const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../stdx/bounded/array.zig").ArrayType;
const EventsType = @import("../syntax/tree.zig").EventsType;
const Language = @import("../syntax/language.zig").Language;
const Structure = @import("../syntax/tree.zig").Structure;
const Tokens = @import("../syntax/tokens.zig");
const TreeType = @import("../syntax/tree.zig").TreeType;
const corpus = @import("../testing/corpus.zig");
const grammars = @import("../syntax/grammars.zig");
const lex_into = @import("../syntax/raw.zig").lex_into;
const markup = @import("../syntax/markup.zig");
const markup_testing = @import("../syntax/testing/markup.zig");
const oracle_names = @import("../syntax/testing/names.zig");
const stripe = @import("../testing/stripe.zig");

const Seen = struct {
    held: [kind_count_max]bool,
    kind_count: u16,

    fn init(kind_count: u16) Seen {
        assert(kind_count > 0);
        assert(kind_count <= kind_count_max);

        return .{ .held = @splat(false), .kind_count = kind_count };
    }

    fn holds(seen: *const Seen, discriminant: u16) bool {
        assert(discriminant < seen.kind_count);

        return seen.held[discriminant];
    }

    fn mark(seen: *Seen, discriminant: u16) void {
        assert(discriminant < seen.kind_count);

        seen.held[discriminant] = true;
    }

    fn held_count(seen: *const Seen) u32 {
        var count: u32 = 0;

        for (seen.held[0..seen.kind_count]) |held| {
            if (held) count += 1;
        }

        assert(count <= seen.kind_count);

        return count;
    }

    fn unreached(seen: *const Seen, found: *[kind_count_max]u16) []const u16 {
        var count: u32 = 0;

        for (seen.held[0..seen.kind_count], 0..) |held, index| {
            if (held) continue;

            found[count] = @intCast(index);
            count += 1;
        }

        assert(count <= seen.kind_count);

        return found[0..count];
    }
};

const Unreachable = struct {
    name: []const u8,
    reason: []const u8,
};

const Subject = struct {
    broken: []const u8,
    extensions: []const []const u8,
    language: Language,
    name: []const u8,
    tsx: bool = false,
    unreachable_kinds: []const Unreachable,
};

const diagnostic_count_max: u32 = 1 << 10;
const event_count_max: u32 = 1 << 19;
const kind_count_max: u16 = 1 << 10;
const markup_node_count_max: u32 = 1 << 17;
const markup_tag_count_max: u32 = 1 << 12;
const markup_token_count_max: u32 = 1 << 18;
const node_count_max: u32 = 1 << 16;
const raw_count_max: u32 = 1 << 16;
const source_bytes_max: u32 = 1 << 24;
const token_count_max: u32 = 1 << 16;
const fixture_root = "tests/fixtures";
const broken_css = "a { color: ` } ^ $ % ? <\n";
const broken_go = "package p\n\nfunc () {\n\t$\n}\n";
const broken_javascript = "let held = ?\x01;\n";
const broken_markup = "<p>held</span>\n";
const broken_odin = "package p\n\nheld := # asm ... => %%=\n";
const broken_python = "@held\n$\n";
const broken_rust = "macro held() {}\n\nfn held() {\n    let held = ~`;\n}\n";
const broken_typescript = "let held = ?\x01;\n";
const broken_zig = "fn ( { $ }\n";

const unreachable_css = [_]Unreachable{
    .{
        .name = "Newline",
        .reason = "the lexer's whitespace_scan eats a line break before token_of sees one, so " ++
            "step_of never maps TokenKind::Newline",
    },
    .{
        .name = "comment",
        .reason = "reserved: css/parse.rs carries no site that wraps a comment token in a node",
    },
    .{
        .name = "error_node",
        .reason = "reserved: css/parse.rs records a SyntaxError and recovers in place, " ++
            "wrapping no error node",
    },
    .{
        .name = "escape_sequence",
        .reason = "reserved: the Escape token stands on its own and css/parse.rs wraps " ++
            "nothing around it",
    },
    .{
        .name = "js_comment",
        .reason = "reserved: css/classify.rs maps every comment to Comment and no site emits " ++
            "the JavaScript form",
    },
    .{
        .name = "string_content",
        .reason = "reserved: a string lexes to one Text token and css/parse.rs wraps it in " ++
            "string_value, never in string_content",
    },
};

const unreachable_go = [_]Unreachable{
    .{
        .name = "BadDecl",
        .reason = "reserved: the kind mirrors go/ast's BadDecl and no site in go/parse.rs " ++
            "opens it",
    },
    .{
        .name = "BadExpr",
        .reason = "reserved: the kind mirrors go/ast's BadExpr and no site in go/parse.rs " ++
            "opens it",
    },
    .{
        .name = "BadStmt",
        .reason = "reserved: the kind mirrors go/ast's BadStmt and no site in go/parse.rs " ++
            "opens it",
    },
    .{
        .name = "EmptyStmt",
        .reason = "reserved: go/parse.rs eats a bare semicolon as a terminator and opens no " ++
            "node for it",
    },
    .{
        .name = "ErrorNode",
        .reason = "reserved: go/parse.rs names it only as the group kind of a frame variant " ++
            "that never closes a group and as the kind of Frame::EMPTY",
    },
};

const unreachable_javascript = [_]Unreachable{
    .{
        .name = "error_node",
        .reason = "reserved: javascript/parse.rs names it only as the group kind of a frame " ++
            "variant that never closes a group and as the kind of Frame::EMPTY",
    },
};

const unreachable_markup = [_]Unreachable{
    .{
        .name = "ErrorToken",
        .reason = "reserved: markup/lexer.rs pushes it only when step consumes no byte or the " ++
            "token table truncates, and a source that lexes Complete does neither",
    },
};

const unreachable_odin = [_]Unreachable{
    .{
        .name = "block_comment",
        .reason = "reserved: odin/parse.rs carries no site that wraps a CommentBlock token in " ++
            "a node",
    },
    .{
        .name = "comment",
        .reason = "reserved: odin/parse.rs carries no site that wraps a Comment token in a node",
    },
    .{
        .name = "error_node",
        .reason = "reserved: odin/parse.rs names it only as the kind of Frame::EMPTY, which " ++
            "every frame overwrites before it closes",
    },
    .{
        .name = "escape_sequence",
        .reason = "reserved: a string lexes to one Text token and odin/parse.rs wraps nothing " ++
            "around its escapes",
    },
    .{
        .name = "field_identifier",
        .reason = "oracle-only: the tree-sitter-odin rule carries precedence -1, so a dotted " ++
            "name before a brace always reduces to a member expression over a struct and the " ++
            "grammar itself never opens the node",
    },
    .{
        .name = "string_content",
        .reason = "reserved: a string lexes to one Text token, so the inner node " ++
            "odin/semantic.rs looks for is never opened",
    },
};

const unreachable_python = [_]Unreachable{
    .{
        .name = "StringFormat",
        .reason = "reserved: classify.rs routes every f-prefixed string through " ++
            "fstring::expand before string_of can name it, and open_string names it only for " ++
            "a format string that carries no quote byte, which a string token never is",
    },
};

const unreachable_rust = [_]Unreachable{
    .{
        .name = "ErrorNode",
        .reason = "reserved: rust/parse.rs names it only as the group kind of a frame variant " ++
            "that never closes a group and as the kind of Frame::EMPTY",
    },
    .{
        .name = "ExprGroup",
        .reason = "reserved: the kind mirrors syn's ExprGroup, which stands for an invisible " ++
            "delimiter a token stream carries and a source file cannot spell",
    },
    .{
        .name = "TypeGroup",
        .reason = "reserved: the kind mirrors syn's TypeGroup, which stands for an invisible " ++
            "delimiter a token stream carries and a source file cannot spell",
    },
};

const unreachable_typescript = [_]Unreachable{
    .{
        .name = "error_node",
        .reason = "reserved: typescript/parse.rs names it only as the group kind of a frame " ++
            "variant that never closes a group and as the kind of Frame::EMPTY",
    },
};

const unreachable_zig = [_]Unreachable{
    .{
        .name = "error_node",
        .reason = "reserved: zig/parse.rs names it only as the kind of Frame::EMPTY, which " ++
            "every frame overwrites before it closes",
    },
};

const css_subject: Subject = .{
    .broken = broken_css,
    .extensions = &.{"css"},
    .language = .css,
    .name = "css",
    .unreachable_kinds = &unreachable_css,
};

const go_subject: Subject = .{
    .broken = broken_go,
    .extensions = &.{"go"},
    .language = .go,
    .name = "go",
    .unreachable_kinds = &unreachable_go,
};

const javascript_subject: Subject = .{
    .broken = broken_javascript,
    .extensions = &.{ "cjs", "js", "jsx", "mjs" },
    .language = .javascript,
    .name = "javascript",
    .unreachable_kinds = &unreachable_javascript,
};

const odin_subject: Subject = .{
    .broken = broken_odin,
    .extensions = &.{"odin"},
    .language = .odin,
    .name = "odin",
    .unreachable_kinds = &unreachable_odin,
};

const python_subject: Subject = .{
    .broken = broken_python,
    .extensions = &.{"py"},
    .language = .python,
    .name = "python",
    .unreachable_kinds = &unreachable_python,
};

const rust_subject: Subject = .{
    .broken = broken_rust,
    .extensions = &.{"rs"},
    .language = .rust,
    .name = "rust",
    .unreachable_kinds = &unreachable_rust,
};

const typescript_subject: Subject = .{
    .broken = broken_typescript,
    .extensions = &.{ "cts", "mts", "ts" },
    .language = .typescript,
    .name = "typescript",
    .unreachable_kinds = &unreachable_typescript,
};

const tsx_subject: Subject = .{
    .broken = broken_typescript,
    .extensions = &.{"tsx"},
    .language = .typescript,
    .name = "tsx",
    .tsx = true,
    .unreachable_kinds = &unreachable_typescript,
};

const zig_subject: Subject = .{
    .broken = broken_zig,
    .extensions = &.{"zig"},
    .language = .zig,
    .name = "zig",
    .unreachable_kinds = &unreachable_zig,
};

fn MachineType(comptime Module: type) type {
    comptime assert(@hasDecl(Module, "Kind"));
    comptime assert(@hasDecl(Module, "Parser"));

    return struct {
        events: Events,
        parser: Module.Parser,
        raw: ArrayType(Module.Kind),
        tokens: Tokens,
        tree: Tree,

        const Machine = @This();
        const Events = EventsType(Module.Kind);
        const Tree = TreeType(Module.Kind);

        fn init(machine: *Machine, gpa: std.mem.Allocator) !void {
            try machine.events.init(gpa, event_count_max);
            errdefer machine.events.deinit(gpa);

            machine.raw = try .init(gpa, raw_count_max);
            errdefer machine.raw.deinit(gpa);

            machine.tokens = try .init(gpa, token_count_max);
            errdefer machine.tokens.deinit(gpa);

            machine.tree = try .init(gpa, node_count_max, diagnostic_count_max);

            assert(machine.raw.empty());
        }

        fn deinit(machine: *Machine, gpa: std.mem.Allocator) void {
            assert(machine.raw.capacity() == raw_count_max);

            machine.tree.deinit(gpa);
            machine.tokens.deinit(gpa);
            machine.raw.deinit(gpa);
            machine.events.deinit(gpa);
        }

        fn run(machine: *Machine, subject: *const Subject, source: []const u8, seen: *Seen) !void {
            assert(source.len <= source_bytes_max);

            try lex_into(
                Module.Kind,
                .{ .flavor = if (subject.tsx) .tsx else .plain, .language = subject.language },
                source,
                &machine.tokens,
                &machine.raw,
            );

            machine.tree.clear();

            const built = try machine.structure_of(subject, source);

            try std.testing.expect(built == .complete);

            for (machine.raw.const_slice()) |kind| seen.mark(@backingInt(kind));
            for (machine.tree.slice()) |node| seen.mark(@backingInt(node.kind));
        }

        fn structure_of(machine: *Machine, subject: *const Subject, source: []const u8) !Structure {
            assert(source.len <= std.math.maxInt(u32));

            const dialected = comptime @hasDecl(Module, "Dialect");
            const held = if (dialected) dialect_of(Module, subject.language, subject.tsx) else {};
            const dialect = if (dialected) .{held.grammar(.module)} else .{};

            assert(machine.tokens.count() == machine.raw.count());

            return @call(.auto, Module.Parser.build, .{
                &machine.parser,
                source,
                machine.tokens.slice(),
                machine.raw.const_slice(),
                &machine.events,
                &machine.tree,
            } ++ dialect);
        }
    };
}

fn dialect_of(comptime Module: type, language: Language, tsx: bool) Module.Dialect {
    assert(language.lexes());

    if (tsx) return .tsx;
    return Module.Dialect.of_language(language);
}

fn extension_matches(subject: *const Subject, basename: []const u8) bool {
    assert(basename.len <= std.math.maxInt(u32));

    const extension = std.Io.Dir.path.extension(basename);
    if (extension.len < 2) return false;

    for (subject.extensions) |wanted| {
        if (std.mem.eql(u8, extension[1..], wanted)) return true;
    }

    return false;
}

fn SelectedType(comptime subject: *const Subject) type {
    return struct {
        fn selected(basename: []const u8) bool {
            assert(basename.len <= std.math.maxInt(u32));

            return extension_matches(subject, basename);
        }
    };
}

fn ReachWorkerType(comptime Module: type) type {
    comptime assert(@hasDecl(Module, "Kind"));
    comptime assert(@typeInfo(Module.Kind).@"enum".field_names.len <= kind_count_max);

    return struct {
        machine: *Machine,
        seen: Seen,
        subject: *const Subject,

        const Machine = MachineType(Module);
        const ReachWorker = @This();
        const kind_count: u16 = @typeInfo(Module.Kind).@"enum".field_names.len;
        pub const Item = corpus.File;
        pub const Shared = struct { subject: *const Subject };

        pub const Tally = struct {
            files: u32,
            reached: @Vector(kind_count_max, u32),
        };

        pub const weight = corpus.File.weight;

        pub fn init(worker: *ReachWorker, gpa: std.mem.Allocator, shared: *const Shared) !void {
            assert(shared.subject.extensions.len > 0);
            assert(shared.subject.name.len > 0);

            worker.machine = try gpa.create(Machine);
            errdefer gpa.destroy(worker.machine);

            try worker.machine.init(gpa);

            worker.seen = .init(kind_count);
            worker.subject = shared.subject;
        }

        pub fn deinit(worker: *ReachWorker, gpa: std.mem.Allocator) void {
            assert(worker.seen.kind_count == kind_count);
            assert(worker.subject.name.len > 0);

            worker.machine.deinit(gpa);
            gpa.destroy(worker.machine);
            worker.* = undefined;
        }

        pub fn visit(worker: *ReachWorker, file: *const corpus.File, tally: *Tally) !void {
            assert(file.name.len > 0);
            assert(file.source.len <= source_bytes_max);

            const subject = worker.subject;

            worker.seen = .init(kind_count);

            try worker.machine.run(subject, file.source, &worker.seen);
            try expect_clean(subject, file.name, worker.machine.tree.diagnostic_slice().len);

            var reached: [kind_count_max]u32 = @splat(0);

            for (worker.seen.held[0..kind_count], 0..) |held, index| {
                if (held) reached[index] = 1;
            }

            tally.files += 1;
            tally.reached += @as(@Vector(kind_count_max, u32), reached);
        }
    };
}

fn gather(comptime Module: type, comptime subject: *const Subject, seen: *Seen) !void {
    const gpa = std.testing.allocator;
    const ReachWorker = ReachWorkerType(Module);
    const selected = SelectedType(subject).selected;

    assert(seen.kind_count == ReachWorker.kind_count);
    assert(subject.extensions.len > 0);

    var files = try corpus.collect(gpa, fixture_root, source_bytes_max, selected);
    defer files.deinit(gpa);

    var tally: ReachWorker.Tally = .{ .files = 0, .reached = @splat(0) };

    try stripe.run(ReachWorker, gpa, &.{ .subject = subject }, files.slice(), &tally);
    try std.testing.expect(tally.files > 0);

    const reached: [kind_count_max]u32 = tally.reached;

    for (reached[0..seen.kind_count], 0..) |count, index| {
        if (count > 0) seen.mark(@intCast(index));
    }

    const machine = try gpa.create(ReachWorker.Machine);
    defer gpa.destroy(machine);

    try machine.init(gpa);
    defer machine.deinit(gpa);

    try machine.run(subject, subject.broken, seen);
}

fn expect_clean(subject: *const Subject, path: []const u8, error_count: usize) !void {
    assert(path.len > 0);

    if (error_count == 0) return;

    std.debug.print("{s}: {s} does not parse cleanly\n", .{ subject.name, path });

    return error.TestUnexpectedResult;
}

fn allow_lists(comptime Kind: type, subject: *const Subject, discriminant: u16) !bool {
    for (subject.unreachable_kinds) |entry| {
        const kind = oracle_names.kind_of(Kind, entry.name) orelse {
            std.debug.print("{s} is allow-listed and is not a kind\n", .{entry.name});

            return error.TestUnexpectedResult;
        };

        if (@backingInt(kind) == discriminant) return true;
    }

    return false;
}

fn judge(comptime Kind: type, subject: *const Subject, seen: *const Seen) !void {
    const kind_count: u16 = @typeInfo(Kind).@"enum".field_names.len;

    for (subject.unreachable_kinds) |entry| {
        const named = oracle_names.kind_of(Kind, entry.name);
        const kind = named orelse return error.TestUnexpectedResult;

        try std.testing.expect(entry.reason.len > 0);
        try std.testing.expect(!seen.holds(@backingInt(kind)));
    }

    var found: [kind_count_max]u16 = undefined;
    var unreached_count: u32 = 0;

    for (seen.unreached(&found)) |discriminant| {
        if (try allow_lists(Kind, subject, discriminant)) continue;

        const kind = Kind.of_u16(discriminant).?;

        std.debug.print("{s}: unreached {s} ({d})\n", .{ subject.name, kind.name(), discriminant });

        unreached_count += 1;
    }

    try std.testing.expectEqual(0, unreached_count);
    try std.testing.expectEqual(kind_count, seen.held_count() + subject.unreachable_kinds.len);
}

fn reach(comptime Module: type, comptime subject: *const Subject) !void {
    const kind_count: u16 = @typeInfo(Module.Kind).@"enum".field_names.len;
    var seen: Seen = .init(kind_count);

    try gather(Module, subject, &seen);
    try judge(Module.Kind, subject, &seen);
}

fn broken(comptime Module: type, subject: *const Subject) !u32 {
    const gpa = std.testing.allocator;
    const kind_count: u16 = @typeInfo(Module.Kind).@"enum".field_names.len;
    const machine = try gpa.create(MachineType(Module));
    defer gpa.destroy(machine);

    try machine.init(gpa);
    defer machine.deinit(gpa);

    var seen: Seen = .init(kind_count);

    try machine.run(subject, subject.broken, &seen);
    try std.testing.expect(machine.tree.diagnostic_slice().len > 0);

    var missing: u32 = 0;

    for ([_]Module.Kind{ .error_node, .error_token }) |kind| {
        const discriminant: u16 = @backingInt(kind);
        if (seen.holds(discriminant)) continue;
        if (try allow_lists(Module.Kind, subject, discriminant)) continue;

        std.debug.print("{s}: the broken source does not reach {s}\n", .{
            subject.name,
            oracle_names.name_of(Module.Kind, kind),
        });

        missing += 1;
    }

    return missing;
}

fn gather_markup(seen: *Seen) !void {
    const gpa = std.testing.allocator;
    const selected = markup_testing.template_selected;

    assert(seen.kind_count == markup.Kind.count);

    var files = try corpus.collect(gpa, fixture_root, source_bytes_max, selected);
    defer files.deinit(gpa);

    try std.testing.expect(files.slice().len > 0);

    var document: markup.Document = try .init(gpa, .{
        .diagnostic_count_max = diagnostic_count_max,
        .node_count_max = markup_node_count_max,
        .tag_count_max = markup_tag_count_max,
        .token_count_max = markup_token_count_max,
    });

    defer document.deinit(gpa);

    for (files.slice()) |file| {
        try run_markup(file.source, file.name, &document, seen);
    }

    try run_markup(broken_markup, "markup: the broken source", &document, seen);
}

fn run_markup(
    source: []const u8,
    label: []const u8,
    document: *markup.Document,
    seen: *Seen,
) !void {
    assert(label.len > 0);
    assert(seen.kind_count == markup.Kind.count);
    assert(source.len <= std.math.maxInt(u32));

    document.parse(source, &markup_testing.vocabulary) catch |err| {
        std.debug.print("{s} does not build whole: {t}\n", .{ label, err });

        return err;
    };

    for (document.tokens()) |token| seen.mark(token.kind.to_u16());
    for (document.tree().slice()) |node| seen.mark(node.kind.to_u16());
}

fn markup_allow_lists(discriminant: u16) !bool {
    for (unreachable_markup) |entry| {
        const kind = oracle_names.kind_of(markup.Kind, entry.name) orelse {
            std.debug.print("{s} is allow-listed and is not a kind\n", .{entry.name});

            return error.TestUnexpectedResult;
        };

        if (kind.to_u16() == discriminant) return true;
    }

    return false;
}

fn judge_markup(seen: *const Seen) !void {
    assert(seen.kind_count == markup.Kind.count);

    for (unreachable_markup) |entry| {
        const named = oracle_names.kind_of(markup.Kind, entry.name);
        const kind = named orelse return error.TestUnexpectedResult;

        try std.testing.expect(entry.reason.len > 0);
        try std.testing.expect(!seen.holds(kind.to_u16()));
    }

    var found: [kind_count_max]u16 = undefined;
    var unreached_count: u32 = 0;

    for (seen.unreached(&found)) |discriminant| {
        if (try markup_allow_lists(discriminant)) continue;

        const kind = markup.Kind.of_u16(discriminant).?;

        std.debug.print("markup: unreached {s} ({d})\n", .{ kind.name(), discriminant });

        unreached_count += 1;
    }

    try std.testing.expectEqual(0, unreached_count);
    try std.testing.expectEqual(markup.Kind.count, seen.held_count() + unreachable_markup.len);
}

test "every css kind is reached by a fixture" {
    try reach(grammars.css, &css_subject);
}

test "every go kind is reached by a fixture" {
    try reach(grammars.go, &go_subject);
}

test "every javascript kind is reached by a fixture of its three dialects" {
    const kind_count: u16 = @typeInfo(grammars.javascript.Kind).@"enum".field_names.len;
    var seen: Seen = .init(kind_count);

    try gather(grammars.javascript, &javascript_subject, &seen);
    try gather(grammars.javascript, &typescript_subject, &seen);
    try gather(grammars.javascript, &tsx_subject, &seen);
    try judge(grammars.javascript.Kind, &javascript_subject, &seen);
}

test "every markup kind is reached by a fixture" {
    var seen: Seen = .init(markup.Kind.count);

    try gather_markup(&seen);
    try judge_markup(&seen);
}

test "every odin kind is reached by a fixture" {
    try reach(grammars.odin, &odin_subject);
}

test "every python kind is reached by a fixture" {
    try reach(grammars.python, &python_subject);
}

test "every rust kind is reached by a fixture" {
    try reach(grammars.rust, &rust_subject);
}

test "every zig kind is reached by a fixture" {
    try reach(grammars.zig, &zig_subject);
}

test "a broken source reaches both error kinds" {
    var missing: u32 = 0;

    missing += try broken(grammars.css, &css_subject);
    missing += try broken(grammars.go, &go_subject);
    missing += try broken(grammars.javascript, &javascript_subject);
    missing += try broken(grammars.odin, &odin_subject);
    missing += try broken(grammars.python, &python_subject);
    missing += try broken(grammars.rust, &rust_subject);
    missing += try broken(grammars.javascript, &typescript_subject);
    missing += try broken(grammars.javascript, &tsx_subject);
    missing += try broken(grammars.zig, &zig_subject);

    try std.testing.expectEqual(0, missing);
}

test "the seen set reports in discriminant order" {
    var seen: Seen = .init(5);

    seen.mark(1);
    seen.mark(3);

    var found: [kind_count_max]u16 = undefined;

    try std.testing.expectEqualSlices(u16, &.{ 0, 2, 4 }, seen.unreached(&found));
}
