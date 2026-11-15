interface Point {
    x: number;
    y: number;
    readonly label?: string;
    move(dx: number, dy: number): void;
    (input: string): number;
    new (input: string): Point;
    [key: string]: unknown;
}

interface Shape extends Point, Named {
    area: number;
}

interface Empty {}

type Alias = Point;
type Union = "a" | "b" | "c";
type Intersect = Point & Named;
type Fn = (input: string) => number;
type Ctor = new (input: string) => Point;
type Nested = { inner: { deep: string } };
type Indexed = Point["x"];
type Keys = keyof Point;
type Query = typeof globalThis;
type Conditional<T> = T extends string ? number : boolean;
type Mapped<T> = { [K in keyof T]: T[K] };
type Optional<T> = { [K in keyof T]?: T[K] };
type Tuple = [first: string, second?: number, ...rest: boolean[]];
type Template = `on${string}`;
type Readonlys = readonly string[];
type Parens = (string | number)[];
type Literal = 1 | -2 | true | null;
type Infer<T> = T extends Array<infer U> ? U : never;
