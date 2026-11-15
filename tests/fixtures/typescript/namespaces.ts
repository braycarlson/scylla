namespace Outer {
    export const value = 1;

    export namespace Inner {
        export type Held = string;
    }
}

module Legacy {
    export const held = 2;
}

declare module "external" {
    export function run(): void;
}

declare global {
    interface Window {
        held: string;
    }
}
