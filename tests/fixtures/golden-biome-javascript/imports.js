import defaulted from "module";
import { named } from "module";
import { named as renamed } from "module";
import defaulted2, { named2 } from "module";
import defaulted3, * as namespace from "module";
import * as everything from "module";
import "side-effect";
import held from "./held.json" with { type: "json" };
import "./held.json" with { type: "json" };

export const value = 1;
export function exported() {}
export class Exported {}
export default exported;
export { value as alias };
export { value };
export * from "module";
export * as space from "module";

async function dynamic() {
    const held = await import("module");

    return import("module");
}

import("module").then(loaded);

const here = import.meta.url;
