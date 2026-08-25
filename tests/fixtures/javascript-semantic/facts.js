import fallback from "./one";
import * as space from "two";
import { named, aliased as renamed } from "./three/four";
import "./side-effect";

const required = require("./five");

require("./six");

export const first = 1;

export function second() {}

export class Third {}

export { first, second as alias };

export default first;

export * from "./seven";

export * as bundle from "./eight";

export { remote, other as renamedRemote } from "./nine";
