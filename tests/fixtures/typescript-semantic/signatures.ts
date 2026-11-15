export function returned(): typeof Returned {
    class Returned {}

    return Returned;
}

export function parameter(value: typeof Parameter) {
    const Parameter = 1;

    return value;
}

export function literal(value: { held: typeof Literal }) {
    let Literal = 1;

    return value;
}

export function hoisted(): Array<typeof Hoisted> {
    var Hoisted = 1;

    return [];
}

export const expressed = function (): typeof Expressed {
    function Expressed() {}

    return 1;
};

export const arrowed = (): typeof Arrowed => {
    const Arrowed = 1;

    return Arrowed;
};

export class Methods {
    method(): typeof Method {
        const Method = 1;

        return 1;
    }

    constructor(value: typeof Constructed) {
        const Constructed = 2;

        value;
    }
}

export function constrained<T extends typeof Constrained>(): T {
    const Constrained = 1;

    return 1 as T;
}

export function typed(): () => typeof Typed {
    const Typed = 1;

    return () => 1;
}

export function nested(): typeof Nested {
    {
        class Nested {}
    }

    return 1;
}

export function overloaded(): typeof Overloaded;
export function overloaded(): number {
    const Overloaded = 1;

    return Overloaded;
}

export function shadowed(): typeof Shadowed {
    const Shadowed = 1;

    return 1;
}

export function later(value: typeof after, after: number) {
    return value;
}

export function defaulted(first = second, second = 1) {
    return first;
}

export function local(): Local {
    interface Local {
        held: number;
    }

    return { held: 1 };
}

export function queried(): typeof Queried {
    interface Queried {
        held: number;
    }

    return 1;
}

const Shadowed = 2;

Shadowed;

declare namespace Ambient {
    export class Held {}
}

declare namespace Unread {
    export class Held {}
}

export class Imported {
    async method(): Promise<typeof Ambient> {
        const { default: Ambient } = await import("./ambient");

        return Ambient;
    }
}
