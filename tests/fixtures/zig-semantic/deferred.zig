fn teardown(value: usize) void {
    _ = value;
}

fn run(seed: usize) usize {
    const held = seed;

    defer teardown(held);
    errdefer teardown(held);

    comptime {
        const early = 1;

        _ = early;
    }

    return held;
}

test "named" {
    const one = 1;

    _ = one;
}
