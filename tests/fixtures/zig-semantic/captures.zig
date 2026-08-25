fn maybe(value: usize) ?usize {
    return value;
}

fn risky(value: usize) !usize {
    return value;
}

fn teardown(value: usize) void {
    _ = value;
}

fn run(items: []const u8, seed: usize) usize {
    var held = seed;

    if (maybe(held)) |value| {
        held = value;
    }

    held = risky(held) catch |err| {
        teardown(seed);
        _ = err;

        return 0;
    };

    for (items, 0..) |item, index| {
        held += item + index;
    }

    while (maybe(held)) |value| {
        held = value;
    }

    switch (held) {
        0 => held = 1,
        else => |other| held = other,
    }

    return held;
}
