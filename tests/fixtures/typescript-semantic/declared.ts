declare namespace Unread {
    const member: number;

    namespace Inner {
        const deep: number;
    }
}

declare namespace Exporting {
    export const shared: number;

    namespace Hidden {}

    class Kept {}

    interface Shape {}

    type Alias = number;

    enum Choice {}

    function signed(): void;

    let counted: number;
}

declare namespace Dotted.Path {
    const held: number;
}

declare module "quiet" {
    const top: number;

    class Shown {}

    interface Hidden {}

    function signed(): void;

    module Inner {
        const deep: number;
    }
}

declare module "loud" {
    export const shared: number;

    const top: number;

    namespace Inner {}

    interface Shape {}
}

declare module Legacy {
    const held: number;

    module Nested {
        const deeper: number;
    }
}

declare class Ambient {}

declare function ambient(): void;

declare enum Choice {}

declare let counted: number;

declare const fixed: number;

declare var hoisted: number;

declare interface Declared {}

declare type Aliased = number;

namespace Plain {
    declare namespace Nested {
        const held: number;
    }
}

declare module "typed" {
    interface Carrier<T> {}

    type Aliased<T> = number;
}

export function overloaded(value: string): string;
export function overloaded(value: number): number;
export function overloaded(value: unknown): unknown {
    return value;
}

function hidden(value: string): string;
function hidden(value: unknown): unknown {
    return value;
}

export {};
