export type Pair<T> = T extends [infer U, infer U] ? U : never;

export type Triple<T> = T extends [infer U, infer U, infer U] ? U : never;

export type Listed<T> = [T] extends [(infer U)[] | { type: (infer U)[] }] ? U : never;

export type Signed<T> = T extends (first: infer U, second: infer U) => void ? U : never;

export type Shadowed<T> = T extends [infer T] ? T : never;

export type Nested<T> = T extends [infer U] ? (T extends [infer U] ? U : 0) : never;

export type Mapped<T> = { [K in keyof T]: { [K in keyof T]: 1 } };
