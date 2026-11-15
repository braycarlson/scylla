const std = @import("std");
const assert = std.debug.assert;
const ArrayType = @import("../stdx/bounded/array.zig").ArrayType;
const Category = @import("category.zig").Category;
const Front = @import("front.zig").Front;
const Language = @import("language.zig").Language;
const Capacity = @import("front.zig").Front.Capacity;
const Options = @import("front.zig").Front.Options;
const Parameter = @import("view.zig").View.Parameter;
const Scratch = @import("front.zig").Front.Scratch;
const Span = @import("../stdx/bounded/span.zig");
const Token = @import("token.zig");
const View = @import("view.zig").View;
const parameter_count_max = @import("view.zig").parameter_count_max;
const python = @import("grammars.zig").python;

const Built = struct {
    front: Front,
    scratch: Scratch,
    source: []const u8,

    fn init(built: *Built, language: Language, source: []const u8) !void {
        const gpa = std.testing.allocator;

        assert(source.len <= std.math.maxInt(u32));
        assert(language != .css);

        built.source = source;

        try built.scratch.init(gpa, &capacity_test, .initOne(language));
        errdefer built.scratch.deinit(gpa);

        try built.front.init(gpa, &capacity_test, language);
        errdefer built.front.deinit(gpa);

        try built.front.parse(&built.scratch, .of(language), source, &options_test);
    }

    fn deinit(built: *Built) void {
        const gpa = std.testing.allocator;

        assert(built.front.tokens().len <= capacity_test.token_count_max);
        assert(built.source.len <= std.math.maxInt(u32));

        built.front.deinit(gpa);
        built.scratch.deinit(gpa);
        built.* = undefined;
    }

    fn count(built: *const Built) u32 {
        const node_count = built.front.node_count();

        assert(node_count > 0);
        assert(built.front.outcome.? == .complete);
        assert(node_count <= capacity_test.node_count_max);

        return node_count;
    }

    fn first(built: *const Built, category: Category) View {
        assert(category != .other);

        const positions = built.index_of(category);

        assert(positions.len > 0);
        assert(positions[0] < built.count());

        return built.view(positions[0]);
    }

    fn index_of(built: *const Built, category: Category) []const u32 {
        assert(category != .other);

        const positions = built.front.nodes_of(category);

        assert(positions.len <= built.count());
        if (positions.len > 0) assert(positions[positions.len - 1] < built.count());

        return positions;
    }

    fn nth(built: *const Built, category: Category, ordinal: u32) View {
        assert(category != .other);

        const positions = built.index_of(category);

        assert(ordinal < positions.len);
        assert(positions[ordinal] < built.count());

        return built.view(positions[ordinal]);
    }

    fn text_at(built: *const Built, position: u32) []const u8 {
        const held = built.tokens();

        assert(position < held.len);
        assert(held[position].end() <= built.source.len);

        return held[position].text(built.source);
    }

    fn tokens(built: *const Built) []const Token {
        const held = built.front.tokens();

        assert(held.len > 0);
        assert(held.len <= capacity_test.token_count_max);

        return held;
    }

    fn view(built: *const Built, node: u32) View {
        assert(node < built.count());

        const held = built.front.view(node).?;

        assert(held.index() == node);

        return held;
    }
};

const Fixture = struct {
    directory: []const u8,
    extension: []const u8,
    language: Language,
};

const fixtures = [_]Fixture{
    .{ .directory = "tests/fixtures/go", .extension = ".go", .language = .go },
    .{ .directory = "tests/fixtures/javascript", .extension = ".js", .language = .javascript },
    .{ .directory = "tests/fixtures/odin", .extension = ".odin", .language = .odin },
    .{ .directory = "tests/fixtures/python", .extension = ".py", .language = .python },
    .{ .directory = "tests/fixtures/rust", .extension = ".rs", .language = .rust },
    .{ .directory = "tests/fixtures/typescript", .extension = ".ts", .language = .typescript },
    .{ .directory = "tests/fixtures/zig", .extension = ".zig", .language = .zig },
};

const fixture_bytes_max = 1 << 20;
const fixture_count_max = 1 << 8;

const capacity_test: Capacity = .{
    .diagnostic_count_max = 1 << 8,
    .event_count_max = 1 << 18,
    .node_count_max = 1 << 16,
    .semantic = .{
        .binding_count_max = 1 << 12,
        .fact_count_max = 1 << 10,
        .reference_count_max = 1 << 12,
        .scope_count_max = 1 << 10,
    },
    .tag_count_max = 1 << 10,
    .token_count_max = 1 << 16,
};

const options_test: Options = .{
    .globals = &.{},
    .python_version = .py310,
    .vocabulary = .empty,
};

const source_javascript = "import { join } from \"path\";\n\nclass Held {\n" ++
    "  constructor(one, two = 2, ...rest) {\n    this.items.push(one);\n  }\n}\n\n" ++
    "const value = 1;\n";

const source_nested_rust = "fn outer(a: u32) -> u32 {\n    let held = |b: u32| b + a;\n\n" ++
    "    match a {\n        0 => 1,\n        _ => held(2),\n    }\n}\n";

fn calls_answer(name: []const u8, built: *const Built) !void {
    assert(name.len > 0);
    assert(built.count() > 0);

    for (built.index_of(.call)) |position| {
        const call = built.view(position).as_call() orelse return error.CallUncast;

        if (call.callee() == null) {
            if (call.name_token() == null) return error.CallUnnamed;
        }

        _ = call.receiver();
        _ = call.arguments().count();
    }
}

fn declarations_answer(built: *const Built) !void {
    assert(built.count() > 0);
    assert(built.tokens().len > 0);

    for (built.index_of(.declaration)) |position| {
        const held = built.view(position);

        if (held.as_declaration()) |declaration| {
            _ = declaration.names().count();
            _ = declaration.type_of();
            _ = declaration.value();
            _ = declaration.is_constant();
        }

        if (held.as_field()) |field| {
            _ = field.name_token();
            _ = field.type_of();
        }
    }

    for (built.index_of(.@"struct")) |position| {
        const container = built.view(position).as_container() orelse continue;

        _ = container.name_token();
        _ = container.fields().count();
        _ = container.members().count();
    }

    try imports_answer(built);
}

fn every_node_answers(name: []const u8, built: *const Built) !void {
    assert(name.len > 0);
    assert(built.source.len > 0);

    for (0..built.count()) |node| {
        const held = built.view(@intCast(node));

        try std.testing.expectEqual(node, held.index());
        try std.testing.expect(held.token_start() <= held.token_end());

        if (held.as_statement()) |statement| {
            _ = statement.header();
            _ = statement.body();
            _ = statement.clauses().count();
        }

        if (held.as_constant()) |constant| _ = constant.literal_class(built.source);
    }

    assert(built.view(0).parent() == null);
}

fn fixture_answers(gpa: std.mem.Allocator, fixture: Fixture, path: []const u8) !void {
    const io = std.testing.io;

    assert(path.len > 0);
    assert(std.mem.endsWith(u8, path, fixture.extension));

    const source = try std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(fixture_bytes_max));
    defer gpa.free(source);

    var built: Built = undefined;

    try built.init(fixture.language, source);
    defer built.deinit();

    try functions_answer(path, &built);
    try calls_answer(path, &built);
    try declarations_answer(&built);
    try every_node_answers(path, &built);
}

fn fixtures_answer(gpa: std.mem.Allocator, fixture: Fixture) !u32 {
    assert(fixture.directory.len <= std.math.maxInt(u32));

    const io = std.testing.io;
    var directory = try std.Io.Dir.cwd().openDir(io, fixture.directory, .{ .iterate = true });
    defer directory.close(io);

    var walker = try directory.walk(gpa);
    defer walker.deinit();

    var found: u32 = 0;

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, fixture.extension)) continue;

        found += 1;

        assert(found <= fixture_count_max);

        const path = try std.Io.Dir.path.join(gpa, &.{ fixture.directory, entry.path });
        defer gpa.free(path);

        try fixture_answers(gpa, fixture, path);
    }

    assert(found <= fixture_count_max);

    return found;
}

fn functions_answer(name: []const u8, built: *const Built) !void {
    assert(name.len > 0);
    assert(built.count() > 0);

    for (built.index_of(.function)) |position| {
        const function = built.view(position).as_function() orelse return error.FunctionUncast;

        try std.testing.expect(function.parameters().count() <= parameter_count_max);

        var parameters = function.parameters();

        for (0..parameter_count_max) |_| {
            const parameter = parameters.next() orelse break;
            const token = parameter.name orelse continue;

            switch (built.tokens()[token].kind) {
                .identifier, .keyword => {},
                else => return error.ParameterNameUnworded,
            }
        }

        _ = function.body();
        _ = function.returns();
        _ = function.receiver();
        _ = function.parameter_nodes().count();
    }
}

fn imports_answer(built: *const Built) !void {
    const gpa = std.testing.allocator;
    var segments: ArrayType(Span) = try .init(gpa, 64);
    defer segments.deinit(gpa);

    assert(segments.capacity() == 64);
    assert(built.count() > 0);

    for (built.index_of(.import)) |position| {
        const import = built.view(position).as_import() orelse continue;

        import.segments(&segments) catch |err| switch (err) {
            error.Truncated => {},
        };

        _ = import.is_wildcard();
    }
}

fn names_expect(built: *const Built, held: View, expected: []const []const u8) !void {
    assert(held.index() < held.node_count());

    const declaration = held.as_declaration().?;
    var names = declaration.names();

    assert(expected.len > 0);
    assert(expected.len < parameter_count_max);

    for (expected) |text| {
        const position = names.next() orelse return error.NameMissing;

        try std.testing.expectEqualStrings(text, built.text_at(position));
    }

    const rest = names.next();

    try std.testing.expectEqual(null, rest);
}

fn nth_declaration(built: *const Built, category: Category, ordinal: u32) ?View {
    var seen: u32 = 0;

    assert(ordinal < parameter_count_max);
    assert(category != .other);
    assert(built.count() > 0);

    for (built.index_of(category)) |position| {
        const held = built.view(position);
        if (held.as_declaration() == null) continue;
        if (seen == ordinal) return held;

        seen += 1;
    }

    return null;
}

fn offset_of(source: []const u8, needle: []const u8) u32 {
    assert(source.len <= std.math.maxInt(u32));
    assert(needle.len > 0);

    const at = std.mem.find(u8, source, needle).?;

    assert(at + needle.len <= source.len);

    return @intCast(at);
}

fn parameters_collect(function: anytype, out: []Parameter) u32 {
    comptime assert(@hasDecl(@TypeOf(function), "parameters"));

    var parameters = function.parameters();
    var total: u32 = 0;

    assert(out.len > 0);

    for (0..out.len + 1) |_| {
        const parameter = parameters.next() orelse break;

        assert(total < out.len);

        out[total] = parameter;
        total += 1;
    }

    return total;
}

test "a go function reads its name parameters receiver and body" {
    const source = "package main\n\nfunc (s *Server) Run(one, two int, three string) error {\n" ++
        "\treturn nil\n}\n";

    var built: Built = undefined;

    try built.init(.go, source);
    defer built.deinit();

    const held = built.first(.function).as_function().?;
    var parameters: [8]Parameter = undefined;
    const parameter_count = parameters_collect(held, &parameters);

    try std.testing.expectEqualStrings("Run", built.text_at(held.name_token().?));
    try std.testing.expectEqual(3, parameter_count);
    try std.testing.expectEqualStrings("one", built.text_at(parameters[0].name.?));
    try std.testing.expectEqualStrings("two", built.text_at(parameters[1].name.?));
    try std.testing.expectEqualStrings("three", built.text_at(parameters[2].name.?));
    try std.testing.expectEqualStrings("int", parameters[1].type_of.?.text(source));
    try std.testing.expect(held.receiver() != null);
    try std.testing.expect(held.body() != null);
    try std.testing.expectEqualStrings("error", held.returns().?.text(source));
}

test "a rust struct container lists its fields as members" {
    const source = "struct Outer {\n    inner: Inner,\n    count: u32,\n}\n";
    var built: Built = undefined;

    try built.init(.rust, source);
    defer built.deinit();

    const held = built.first(.@"struct").as_container().?;
    var members = held.body().children();
    const member_count = members.count();
    const member = members.next().?;
    const spelled = member.type_of().?;

    try std.testing.expectEqual(2, member_count);
    try std.testing.expectEqualStrings("inner", built.text_at(member.name_token().?));
    try std.testing.expectEqualStrings("Inner", spelled.span().text(source));
}

test "a rust parameter reads its type" {
    const source = "fn run(other: &Outer) {}\n";
    var built: Built = undefined;

    try built.init(.rust, source);
    defer built.deinit();

    const held = built.first(.declaration);
    const spelled = held.type_of().?;

    try std.testing.expectEqualStrings("&Outer", spelled.span().text(source));
}

test "a go call reads its receiver name and arguments" {
    const source = "package main\n\nfunc run() {\n\tserver.Start(one, two)\n}\n";
    var built: Built = undefined;

    try built.init(.go, source);
    defer built.deinit();

    const held = built.first(.call).as_call().?;

    try std.testing.expectEqualStrings("Start", built.text_at(held.name_token().?));
    try std.testing.expectEqualStrings("server", held.receiver().?.text(source));
    try std.testing.expectEqual(2, held.arguments().count());
}

test "a go declaration reads its names and constness" {
    const source = "package main\n\nconst one, two = 1, 2\n\nvar three = 3\n";
    var built: Built = undefined;

    try built.init(.go, source);
    defer built.deinit();

    const constant = nth_declaration(&built, .declaration, 0).?;
    const declaration = constant.as_declaration().?;

    try names_expect(&built, constant, &.{ "one", "two" });
    try std.testing.expect(declaration.is_constant());
    try std.testing.expectEqualStrings("1", declaration.value().?.text(source));
}

test "a rust function reads its name parameters return and body" {
    const source = "pub fn run(&self, one: u32, mut two: &[u8]) -> bool {\n    true\n}\n";
    var built: Built = undefined;

    try built.init(.rust, source);
    defer built.deinit();

    const held = built.first(.function).as_function().?;
    var parameters: [8]Parameter = undefined;
    const parameter_count = parameters_collect(held, &parameters);

    try std.testing.expectEqualStrings("run", built.text_at(held.name_token().?));
    try std.testing.expectEqual(3, parameter_count);
    try std.testing.expectEqualStrings("self", built.text_at(parameters[0].name.?));
    try std.testing.expectEqualStrings("one", built.text_at(parameters[1].name.?));
    try std.testing.expectEqualStrings("u32", parameters[1].type_of.?.text(source));
    try std.testing.expectEqualStrings("two", built.text_at(parameters[2].name.?));
    try std.testing.expect(held.receiver() != null);
    try std.testing.expect(held.is_public());
    try std.testing.expectEqualStrings("bool", held.returns().?.text(source));
    try std.testing.expect(held.body() != null);
}

test "a rust declaration and a method call read through the view" {
    const source = "fn run() {\n    let mut held: u32 = 1;\n    let (one, two) = pair();" ++
        "\n    held.push(one, two);\n}\n";

    var built: Built = undefined;

    try built.init(.rust, source);
    defer built.deinit();

    const local = built.first(.declaration);
    const declaration = local.as_declaration().?;

    try names_expect(&built, local, &.{"held"});
    try std.testing.expect(declaration.is_mutable());
    try std.testing.expect(!declaration.is_constant());
    try std.testing.expectEqualStrings("u32", declaration.type_of().?.text(source));
    try std.testing.expectEqualStrings("1", declaration.value().?.text(source));

    const pair = nth_declaration(&built, .declaration, 1).?;

    try names_expect(&built, pair, &.{ "one", "two" });

    const call = for (built.index_of(.call)) |position| {
        const found = built.view(position).as_call().?;
        if (found.receiver() != null) break found;
    } else return error.MethodCallMissing;

    try std.testing.expectEqualStrings("push", built.text_at(call.name_token().?));
    try std.testing.expectEqualStrings("held", call.receiver().?.text(source));
    try std.testing.expectEqual(2, call.arguments().count());
}

test "a rust container and use read through the view" {
    const gpa = std.testing.allocator;

    const source = "use std::collections::HashMap;\n\npub struct Held {\n    one: u32,\n" ++
        "    two: bool,\n}\n\nimpl Held {\n    fn run(&self) {}\n}\n";

    var built: Built = undefined;

    try built.init(.rust, source);
    defer built.deinit();

    const import = built.first(.import).as_import().?;
    var segments: ArrayType(Span) = try .init(gpa, 16);
    defer segments.deinit(gpa);

    try import.segments(&segments);
    try std.testing.expectEqual(3, segments.count());
    try std.testing.expectEqualStrings("HashMap", segments.get(2).text(source));
    try std.testing.expect(!import.is_wildcard());

    const held = built.first(.@"struct").as_container().?;

    try std.testing.expectEqualStrings("Held", built.text_at(held.name_token().?));
    try std.testing.expectEqual(2, held.fields().count());

    const block = built.nth(.@"struct", 1).as_container().?;

    try std.testing.expectEqual(1, block.members().count());
}

test "a python function reads its parameters defaults and annotations" {
    const source = "def run(self, one: int, two=2, *rest, **named) -> bool:\n    return True\n";
    var built: Built = undefined;

    try built.init(.python, source);
    defer built.deinit();

    const held = built.first(.function).as_function().?;
    var parameters: [8]Parameter = undefined;
    const parameter_count = parameters_collect(held, &parameters);

    try std.testing.expectEqualStrings("run", built.text_at(held.name_token().?));
    try std.testing.expectEqual(5, parameter_count);
    try std.testing.expectEqualStrings("one", built.text_at(parameters[1].name.?));
    try std.testing.expectEqualStrings("int", parameters[1].type_of.?.text(source));
    try std.testing.expectEqualStrings("2", parameters[2].default.?.text(source));
    try std.testing.expectEqualStrings("bool", held.returns().?.text(source));
    try std.testing.expect(held.body() != null);
}

test "a python class call and import read through the view" {
    const gpa = std.testing.allocator;

    const source = "from os.path import join\n\nclass Held:\n    def run(self):\n" ++
        "        self.items.append(1)\n\n    def stop(self):\n        pass\n\nvalue = 1\n";

    var built: Built = undefined;

    try built.init(.python, source);
    defer built.deinit();

    const class = built.first(.@"struct").as_container().?;

    try std.testing.expectEqualStrings("Held", built.text_at(class.name_token().?));
    try std.testing.expectEqual(2, class.members().count());

    const call = built.first(.call).as_call().?;

    try std.testing.expectEqualStrings("append", built.text_at(call.name_token().?));
    try std.testing.expectEqualStrings("self.items", call.receiver().?.text(source));
    try std.testing.expectEqual(1, call.arguments().count());

    const import = built.first(.import).as_import().?;
    var segments: ArrayType(Span) = try .init(gpa, 16);
    defer segments.deinit(gpa);

    try import.segments(&segments);
    try std.testing.expectEqual(2, segments.count());
    try std.testing.expectEqualStrings("path", segments.get(1).text(source));

    const value = nth_declaration(&built, .declaration, 0).?;

    try names_expect(&built, value, &.{"value"});
}

test "a zig function reads its parameters from the prototype" {
    const source = "pub fn run(one: u32, two: []const u8, comptime T: type) !void {\n" ++
        "    _ = one;\n}\n";

    var built: Built = undefined;

    try built.init(.zig, source);
    defer built.deinit();

    const held = built.first(.function).as_function().?;
    var parameters: [8]Parameter = undefined;
    const parameter_count = parameters_collect(held, &parameters);

    try std.testing.expectEqualStrings("run", built.text_at(held.name_token().?));
    try std.testing.expectEqual(3, parameter_count);
    try std.testing.expectEqualStrings("one", built.text_at(parameters[0].name.?));
    try std.testing.expectEqualStrings("u32", parameters[0].type_of.?.text(source));
    try std.testing.expectEqualStrings("two", built.text_at(parameters[1].name.?));
    try std.testing.expectEqualStrings("T", built.text_at(parameters[2].name.?));
    try std.testing.expect(held.is_public());
    try std.testing.expect(held.returns() != null);
    try std.testing.expect(held.body() != null);
}

test "a zig container call and declaration read through the view" {
    const source = "const Held = struct {\n    one: u32 = 0,\n    fn run(self: Held) void {\n" ++
        "        std.debug.print(\"{}\", .{self.one});\n    }\n};\n";

    var built: Built = undefined;

    try built.init(.zig, source);
    defer built.deinit();

    const container = built.first(.@"struct").as_container().?;

    try std.testing.expectEqualStrings("Held", built.text_at(container.name_token().?));
    try std.testing.expectEqual(1, container.fields().count());
    try std.testing.expectEqual(1, container.members().count());

    const call = built.first(.call).as_call().?;

    try std.testing.expectEqualStrings("print", built.text_at(call.name_token().?));
    try std.testing.expectEqualStrings("std.debug", call.receiver().?.text(source));
    try std.testing.expectEqual(2, call.arguments().count());

    const declaration = built.first(.declaration);

    try names_expect(&built, declaration, &.{"Held"});
    try std.testing.expect(declaration.as_declaration().?.is_constant());
}

test "an odin procedure reads its parameters and returns" {
    const source = "package main\n\nrun :: proc(one, two: int, three: string = \"\") -> bool {\n" ++
        "    return true\n}\n";

    var built: Built = undefined;

    try built.init(.odin, source);
    defer built.deinit();

    const held = built.first(.function).as_function().?;
    var parameters: [8]Parameter = undefined;
    const parameter_count = parameters_collect(held, &parameters);

    try std.testing.expectEqualStrings("run", built.text_at(held.name_token().?));
    try std.testing.expectEqual(3, parameter_count);
    try std.testing.expectEqualStrings("one", built.text_at(parameters[0].name.?));
    try std.testing.expectEqualStrings("two", built.text_at(parameters[1].name.?));
    try std.testing.expectEqualStrings("int", parameters[1].type_of.?.text(source));
    try std.testing.expect(parameters[2].default != null);
    try std.testing.expectEqualStrings("bool", held.returns().?.text(source));
    try std.testing.expect(held.body() != null);
}

test "a javascript function call and class read through the view" {
    var built: Built = undefined;

    try built.init(.javascript, source_javascript);
    defer built.deinit();

    const held = built.first(.function).as_function().?;
    var parameters: [8]Parameter = undefined;
    const parameter_count = parameters_collect(held, &parameters);

    try std.testing.expectEqual(3, parameter_count);
    try std.testing.expectEqualStrings("one", built.text_at(parameters[0].name.?));
    try std.testing.expectEqualStrings("two", built.text_at(parameters[1].name.?));
    try std.testing.expectEqualStrings("2", parameters[1].default.?.text(source_javascript));
    try std.testing.expectEqualStrings("rest", built.text_at(parameters[2].name.?));
    try std.testing.expect(held.body() != null);

    const call = built.first(.call).as_call().?;

    try std.testing.expectEqualStrings("push", built.text_at(call.name_token().?));
    try std.testing.expectEqualStrings("this.items", call.receiver().?.text(source_javascript));
    try std.testing.expectEqual(1, call.arguments().count());
}

test "a javascript class import and declaration read through the view" {
    const gpa = std.testing.allocator;
    var built: Built = undefined;

    try built.init(.javascript, source_javascript);
    defer built.deinit();

    const class = built.first(.@"struct").as_container().?;

    try std.testing.expectEqualStrings("Held", built.text_at(class.name_token().?));
    try std.testing.expectEqual(1, class.members().count());

    const import = built.first(.import).as_import().?;
    var segments: ArrayType(Span) = try .init(gpa, 16);
    defer segments.deinit(gpa);

    try import.segments(&segments);
    try std.testing.expectEqual(1, segments.count());

    const value = nth_declaration(&built, .declaration, 0).?;

    try names_expect(&built, value, &.{"value"});
    try std.testing.expect(value.as_declaration().?.is_constant());
}

test "a typescript function reads typed parameters" {
    const source = "export function run(one: number, two?: string, three = 3): boolean {\n" ++
        "  return true;\n}\n";

    var built: Built = undefined;

    try built.init(.typescript, source);
    defer built.deinit();

    const held = built.first(.function).as_function().?;
    var parameters: [8]Parameter = undefined;
    const parameter_count = parameters_collect(held, &parameters);

    try std.testing.expectEqualStrings("run", built.text_at(held.name_token().?));
    try std.testing.expectEqual(3, parameter_count);
    try std.testing.expectEqualStrings("one", built.text_at(parameters[0].name.?));
    try std.testing.expect(parameters[0].type_of != null);
    try std.testing.expectEqualStrings("two", built.text_at(parameters[1].name.?));
    try std.testing.expectEqualStrings("three", built.text_at(parameters[2].name.?));
    try std.testing.expectEqualStrings("3", parameters[2].default.?.text(source));
    try std.testing.expect(held.returns() != null);
}

test "a typescript function reads a type predicate or an assertion as its return type" {
    const Case = struct { source: []const u8, returns: []const u8 };

    const cases = [_]Case{
        .{
            .source = "function a(page: P): boolean {\n  return true;\n}\n",
            .returns = ": boolean",
        },
        .{
            .source = "function b(page: P): page is Q {\n  return true;\n}\n",
            .returns = ": page is Q",
        },
        .{
            .source = "function c(page: P): asserts page is Q {}\n",
            .returns = ": asserts page is Q",
        },
        .{ .source = "function d(page: P): asserts page {}\n", .returns = ": asserts page" },
        .{ .source = "function e(page: P) {}\n", .returns = "" },
    };

    for (cases) |case| {
        var built: Built = undefined;

        try built.init(.typescript, case.source);
        defer built.deinit();

        const held = built.first(.function).as_function().?;
        const span = held.returns_span() orelse Span{ .offset = 0, .length = 0 };

        try std.testing.expectEqualStrings(case.returns, span.text(case.source));
    }
}

test "a parameter reads whether it gathers the remaining arguments" {
    const Case = struct { language: Language, source: []const u8, variadic: []const bool };

    const cases = [_]Case{
        .{
            .language = .python,
            .source = "def run(self, one, *rest, two=2, **named):\n    pass\n",
            .variadic = &.{ false, false, true, false, true },
        },
        .{
            .language = .python,
            .source = "def run(one, *, two):\n    pass\n",
            .variadic = &.{ false, false },
        },
        .{
            .language = .javascript,
            .source = "function run(one, ...rest) {}\n",
            .variadic = &.{ false, true },
        },
        .{
            .language = .typescript,
            .source = "function run(one: number, ...rest: number[]) {}\n",
            .variadic = &.{ false, true },
        },
        .{
            .language = .go,
            .source = "package main\n\nfunc run(one int, rest ...int) {}\n",
            .variadic = &.{ false, true },
        },
        .{
            .language = .odin,
            .source = "package main\n\nrun :: proc(one: int, rest: ..int) {}\n",
            .variadic = &.{ false, true },
        },
        .{
            .language = .rust,
            .source = "fn run(one: u32, rest: &[u32]) {}\n",
            .variadic = &.{ false, false },
        },
        .{
            .language = .zig,
            .source = "fn run(one: u32, rest: []const u32) void {}\n",
            .variadic = &.{ false, false },
        },
    };

    for (cases) |case| {
        var built: Built = undefined;

        try built.init(case.language, case.source);
        defer built.deinit();

        const held = built.first(.function).as_function().?;
        var parameters: [8]Parameter = undefined;
        const parameter_count = parameters_collect(held, &parameters);

        try std.testing.expectEqual(case.variadic.len, parameter_count);

        for (case.variadic, parameters[0..parameter_count]) |variadic, parameter| {
            try std.testing.expectEqual(variadic, parameter.variadic);
        }
    }
}

test "a spread argument names the call it unpacks into and nothing else does" {
    const Case = struct { language: Language, source: []const u8, spread: []const []const u8 };

    const cases = [_]Case{
        .{
            .language = .python,
            .source = "def run(*rest, **named):\n    work(1, *rest, key=rest, **named)\n" ++
                "    return [*rest]\n",
            .spread = &.{ "rest", "named" },
        },
        .{
            .language = .javascript,
            .source = "function run(...rest) {\n  work(1, ...rest);\n  return [...rest];\n}\n",
            .spread = &.{"rest"},
        },
        .{
            .language = .typescript,
            .source = "function run(...rest: number[]) {\n  work(...rest);\n  work(rest);\n}\n",
            .spread = &.{"rest"},
        },
        .{
            .language = .go,
            .source = "package main\n\nfunc run(rest ...int) {\n\twork(1, rest...)\n" ++
                "\twork(rest)\n}\n",
            .spread = &.{"rest"},
        },
        .{
            .language = .odin,
            .source = "package main\n\nrun :: proc(rest: ..int) {\n\twork(1, ..rest)\n" ++
                "\twork(rest)\n}\n",
            .spread = &.{"rest"},
        },
        .{
            .language = .rust,
            .source = "fn run(rest: &[u32]) {\n    work(rest);\n}\n",
            .spread = &.{},
        },
        .{
            .language = .zig,
            .source = "fn run(rest: []const u32) void {\n    work(rest);\n}\n",
            .spread = &.{},
        },
    };

    for (cases) |case| {
        var built: Built = undefined;

        try built.init(case.language, case.source);
        defer built.deinit();

        var found: u32 = 0;

        for (0..built.count()) |position| {
            const held = built.view(@intCast(position));
            const call = held.spread_call() orelse continue;

            try std.testing.expect(found < case.spread.len);
            try std.testing.expectEqualStrings(case.spread[found], held.text(case.source));
            try std.testing.expect(call.view.index() < held.index());
            try std.testing.expectEqualStrings("work", built.text_at(call.name_token().?));

            found += 1;
        }

        try std.testing.expectEqual(case.spread.len, found);
    }
}

test "a class container reads the bases it derives from" {
    const Case = struct { language: Language, source: []const u8, bases: []const []const u8 };

    const cases = [_]Case{
        .{
            .language = .python,
            .source = "class Held(Base, mixins.Other, metaclass=Meta):\n    pass\n",
            .bases = &.{ "Base", "mixins.Other" },
        },
        .{
            .language = .python,
            .source = "class Held:\n    pass\n",
            .bases = &.{},
        },
        .{
            .language = .javascript,
            .source = "class Held extends Base {}\n",
            .bases = &.{"Base"},
        },
        .{
            .language = .typescript,
            .source = "class Held extends Base<number> implements Shape {}\n",
            .bases = &.{"Base"},
        },
        .{
            .language = .rust,
            .source = "struct Held {\n    one: u32,\n}\n",
            .bases = &.{},
        },
    };

    for (cases) |case| {
        var built: Built = undefined;

        try built.init(case.language, case.source);
        defer built.deinit();

        const class = built.first(.@"struct").as_container().?;
        var bases = class.bases();

        try std.testing.expectEqual(case.bases.len, bases.count());

        for (case.bases) |expected| {
            const base = bases.next() orelse return error.TestUnexpectedResult;

            try std.testing.expectEqualStrings(expected, base.text(case.source));
        }

        const past = bases.next();

        try std.testing.expectEqual(null, past);
    }
}

test "parameters past the bound are cut and the cut is reported" {
    var buffer: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);

    try writer.writeAll("def wide(");

    for (0..parameter_count_max + 1) |index| {
        try writer.print("p{d}, ", .{index});
    }

    try writer.writeAll("):\n    pass\n");

    var built: Built = undefined;

    try built.init(.python, writer.buffered());
    defer built.deinit();

    const function = built.first(.function).as_function().?;
    var parameters = function.parameters();

    try std.testing.expectEqual(parameter_count_max, parameters.count());
    try std.testing.expect(!parameters.truncated());

    for (0..parameter_count_max) |_| {
        _ = parameters.next().?;
    }

    try std.testing.expect(parameters.truncated());

    const parameters_next = parameters.next();

    try std.testing.expectEqual(null, parameters_next);
}

test "a statement reads its clauses in every language" {
    const Case = struct { language: Language, source: []const u8, category: Category, count: u32 };

    const cases = [_]Case{
        .{
            .language = .go,
            .source = "package main\n\nfunc run(one int) {\n\tswitch one {\n\tcase 1:\n" ++
                "\tcase 2:\n\tdefault:\n\t}\n}\n",
            .category = .match,
            .count = 3,
        },
        .{
            .language = .rust,
            .source = "fn run(one: u32) {\n    match one {\n        1 => {}\n        2 => {}\n" ++
                "        _ => {}\n    }\n}\n",
            .category = .match,
            .count = 3,
        },
        .{
            .language = .python,
            .source = "def run(one):\n    try:\n        pass\n    except ValueError:\n" ++
                "        pass\n    except KeyError:\n        pass\n    finally:\n        pass\n",
            .category = .@"try",
            .count = 3,
        },
        .{
            .language = .zig,
            .source = "fn run(one: u32) void {\n    switch (one) {\n        1 => {},\n" ++
                "        2 => {},\n        else => {},\n    }\n}\n",
            .category = .match,
            .count = 3,
        },
        .{
            .language = .javascript,
            .source = "function run(one) {\n  if (one) {\n  } else {\n  }\n}\n",
            .category = .branch,
            .count = 1,
        },
    };

    for (cases) |case| {
        var built: Built = undefined;

        try built.init(case.language, case.source);
        defer built.deinit();

        const held = built.first(case.category).as_statement().?;

        try std.testing.expectEqual(case.count, held.clauses().count());
    }
}

test "every fixture answers the typed questions without panicking" {
    const gpa = std.testing.allocator;

    for (fixtures) |fixture| {
        const found = try fixtures_answer(gpa, fixture);

        try std.testing.expect(found > 0);
    }
}

test "the enclosing function is the nearest function or lambda" {
    var built: Built = undefined;

    try built.init(.rust, source_nested_rust);
    defer built.deinit();

    const outer = built.first(.function);
    const lambda = built.first(.lambda);
    const call = built.first(.call);
    const inner = lambda.children().last().?;

    try std.testing.expectEqual(outer.index(), lambda.enclosing_function().?.index());
    try std.testing.expectEqual(outer.index(), call.enclosing_function().?.index());
    try std.testing.expectEqual(lambda.index(), inner.enclosing_function().?.index());
    try std.testing.expectEqual(null, outer.enclosing_function());
}

test "an arm sits under a match in rust and zig" {
    const source_zig = "fn run(value: u32) u32 {\n    return switch (value) {\n" ++
        "        0 => 1,\n        else => 2,\n    };\n}\n";

    const Case = struct { language: Language, source: []const u8 };

    const cases = [_]Case{
        .{ .language = .rust, .source = source_nested_rust },
        .{ .language = .zig, .source = source_zig },
    };

    for (cases) |case| {
        var built: Built = undefined;

        try built.init(case.language, case.source);
        defer built.deinit();

        const held = built.first(.match);
        var children = held.children();
        var arms: u32 = 0;

        for (0..children.count()) |_| {
            if (children.next().?.is_an_arm()) arms += 1;
        }

        try std.testing.expect(arms >= 2);
        try std.testing.expect(!held.is_an_arm());
        try std.testing.expect(!built.first(.function).is_an_arm());
    }
}

test "a parameter sits inside a signature and a local does not" {
    var built: Built = undefined;

    try built.init(.rust, source_nested_rust);
    defer built.deinit();

    var children = built.first(.parameters).children();

    const parameter = for (0..children.count()) |_| {
        const held = children.next().?;
        if (held.span().offset == offset_of(source_nested_rust, "a: u32")) break held;
    } else return error.ParameterMissing;

    try std.testing.expect(parameter.is_inside_signature());

    const local = for (built.index_of(.declaration)) |position| {
        const held = built.view(position);
        if (held.span().offset == offset_of(source_nested_rust, "let held")) break held;
    } else return error.LocalMissing;

    try std.testing.expect(!local.is_inside_signature());
}

test "a signature covers the offsets before the body opens" {
    var built: Built = undefined;

    try built.init(.rust, source_nested_rust);
    defer built.deinit();

    const outer = built.first(.function);
    const end: u32 = @intCast(source_nested_rust.len);

    try std.testing.expect(outer.signature_covers(offset_of(source_nested_rust, "a: u32")));
    try std.testing.expect(outer.signature_covers(offset_of(source_nested_rust, "-> u32")));
    try std.testing.expect(!outer.signature_covers(offset_of(source_nested_rust, "let held")));
    try std.testing.expect(!outer.signature_covers(end));
    try std.testing.expect(!built.first(.match).signature_covers(0));
}

test "function at names the innermost function covering an offset" {
    var built: Built = undefined;

    try built.init(.rust, source_nested_rust);
    defer built.deinit();

    const front = &built.front;
    const outer = built.first(.function);
    const lambda = built.first(.lambda);
    const inside_lambda = offset_of(source_nested_rust, "b + a");
    const inside_match = offset_of(source_nested_rust, "match a");

    try std.testing.expectEqual(lambda.index(), front.function_at(inside_lambda).?.index());
    try std.testing.expectEqual(outer.index(), front.function_at(inside_match).?.index());
    try std.testing.expectEqual(outer.index(), front.function_at(0).?.index());
    try std.testing.expectEqual(null, front.function_at(std.math.maxInt(u32)));
}

test "a front names a declaration and a view at an offset" {
    const source = "const Held = struct {\n    one: u32 = 0,\n};\n\nconst other = Held;\n";
    var built: Built = undefined;

    try built.init(.zig, source);
    defer built.deinit();

    const front = &built.front;
    const declaration = built.first(.declaration);
    const declared = front.declaration_of("Held").?;
    const held = front.view_at(.declaration, 0).?;

    try std.testing.expect(declared < front.node_count());
    try std.testing.expectEqual(null, front.declaration_of("missing"));
    try std.testing.expectEqual(declaration.index(), held.index());
    try std.testing.expectEqual(null, front.view_at(.declaration, 1));
    try std.testing.expectEqual(0, front.root().?.index());
    try std.testing.expectEqual(0, front.diagnostics().len);
    try std.testing.expect(front.tokens().len > 0);
}
