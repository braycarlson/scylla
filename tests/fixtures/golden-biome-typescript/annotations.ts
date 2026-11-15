let count: number = 1;
let names: string[] = [];
let pair: [string, number] = ["a", 1];
const flag: boolean = true;

function widen(value: unknown, held?: string, ...rest: number[]): void {}

function guard(value: unknown): value is string {
    return typeof value === "string";
}

function check(value: unknown): asserts value is string {}

class Holder {
    private readonly name: string;
    protected count: number = 0;
    public flag?: boolean;
    static held: string;

    constructor(
        private value: number,
        readonly label: string,
    ) {}

    run(input: string, fallback: number = 1): string {
        return input;
    }
}

const arrow = (left: number, right: number): number => left + right;
const method: (left: number) => number = (value) => value;
const tail: [string, number?, ...boolean[]] = ["a"];
