const outer = 1;

function middle() {
    const held = outer;

    {
        const inner = held;

        return inner;
    }
}
