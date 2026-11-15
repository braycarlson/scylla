const std = @import("std");
const scylla = @import("scylla");
const assert = std.debug.assert;

const capacity: scylla.Front.Capacity = .{
    .diagnostic_count_max = 1 << 6,
    .event_count_max = 1 << 12,
    .node_count_max = 1 << 10,
    .semantic = .{
        .binding_count_max = 1 << 8,
        .fact_count_max = 1 << 6,
        .reference_count_max = 1 << 8,
        .scope_count_max = 1 << 6,
    },
    .tag_count_max = 1 << 6,
    .token_count_max = 1 << 10,
};

const source =
    \\def greet(name, punctuation="!"):
    \\    return name + punctuation
    \\
    \\def shout(name):
    \\    return greet(name.upper())
    \\
    \\def broken(:
    \\    pass
    \\
;

pub fn main(init: std.process.Init) !void {
    assert(init.minimal.args.vector.len > 0);

    const gpa = init.gpa;
    const fronts = try gpa.create(scylla.Fronts);
    defer gpa.destroy(fronts);

    try fronts.init(gpa, &capacity, .initOne(.python), &.{});
    defer fronts.deinit(gpa);

    const front = try fronts.parse(.of(.python), source);
    const tokens = front.tokens();

    for (front.nodes_of(.function)) |node| {
        const function = front.view(node).?.as_function().?;
        const name = tokens[function.name_token().?].text(source);
        const parameters = function.parameters();

        std.debug.print("{s} takes {d}\n", .{ name, parameters.count() });
    }

    var buffer: [256]u8 = undefined;

    for (front.diagnostics()) |diagnostic| {
        var writer: std.Io.Writer = .fixed(&buffer);

        try front.diagnostic_write(diagnostic, &writer);

        std.debug.print("{d}: {s}\n", .{ diagnostic.span.offset, writer.buffered() });
    }

    assert(front.nodes_of(.function).len == 3);
    assert(front.has_diagnostics());
}
