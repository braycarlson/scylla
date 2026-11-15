function identity<T>(value: T): T {
    return value;
}

function bounded<T extends object, U = string>(left: T, right: U): void {}

class Box<T> {
    value: T;

    map<U>(transform: (input: T) => U): Box<U> {
        return new Box<U>();
    }
}

interface Pair<A, B> {
    left: A;
    right: B;
}

const held = identity<string>("a");
const made = new Box<number>();
type Deep = Map<string, Array<number>>;
type Qualified = Outer.Inner.Held;
type Optionalised<Held> = { [Key in keyof Held]+?: Held[Key] };
type Demanded<Held> = { [Key in keyof Held]-?: Held[Key] };
