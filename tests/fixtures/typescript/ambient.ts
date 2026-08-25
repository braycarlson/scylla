declare const version: string;
declare let mutable: number;
declare function run(input: string): void;
declare class Held {
    name: string;
    run(): void;
}
declare namespace Outer {
    const value: number;
}
export declare function exported(): void;

abstract class Base {
    abstract run(): void;
    abstract readonly name: string;

    protected abstract held(input: string): number;

    concrete(): void {}
}

import type { Point } from "./point";
import { type Shape, Named } from "./shape";
export type { Point };
export * as held from "./held";
import legacy = require("./legacy");
import Alias = Outer.Inner;
