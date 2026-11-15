fn run(one: usize) usize {
    const held = one;
    var kept: usize = held;

    {
        const held = kept;

        kept = held;
    }

    const value = blk: {
        const inner = kept;

        break :blk inner;
    };

    var index: usize = 0;

    while (index < value) : (index += 1) {
        kept += index;
    }

    return kept + value;
}
