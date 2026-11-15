interface Shape {
    area: number;
}

interface Shape {
    name: string;
}

class Widget {}

interface Widget {
    extra: number;
}

function overload(one: number): number {
    return one;
}

namespace overload {
    export const version = 1;
}

const held: Shape = { area: 1, name: "a" };
