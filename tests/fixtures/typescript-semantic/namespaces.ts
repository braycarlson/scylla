type Alias = number;

enum Colour {
    Red,
    Blue,
}

interface Only {
    field: Alias;
}

import type { Remote } from "other";

const value: Colour = Colour.Red;

const typed: Remote = value;

const missing: Only = value;
