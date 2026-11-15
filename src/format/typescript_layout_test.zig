const std = @import("std");
const expect_formatted = @import("typescript_test.zig").expect_formatted;
const expect_formatted_tsx = @import("typescript_test.zig").expect_formatted_tsx;

test "a member named like a cast word keeps its union after the colon" {
    const source = "interface L {\n" ++
        "\tas?:\n" ++
        "\t\t| 'fetch'\n" ++
        "\t\t| 'audio'\n" ++
        "\t\t| 'audioworklet'\n" ++
        "\t\t| 'document'\n" ++
        "\t\t| 'embed'\n" ++
        "\t\t| 'font'\n" ++
        "\t\t| 'frame'\n" ++
        "\t\t| 'iframe';\n" ++
        "\tsatisfies: 'fetch' | 'audio' | 'audioworklet' | 'document' | 'embed' | " ++
        "'font' | 'frame';\n" ++
        "}\n" ++
        "class C {\n" ++
        "\tas(value: string): string | number | boolean | undefined | null | symbol " ++
        "| bigint | object {\n" ++
        "\t\treturn value;\n" ++
        "\t}\n" ++
        "}\n";

    const wanted = "interface L {\n" ++
        "    as?:\n" ++
        "        | \"fetch\"\n" ++
        "        | \"audio\"\n" ++
        "        | \"audioworklet\"\n" ++
        "        | \"document\"\n" ++
        "        | \"embed\"\n" ++
        "        | \"font\"\n" ++
        "        | \"frame\"\n" ++
        "        | \"iframe\";\n" ++
        "    satisfies:\n" ++
        "        | \"fetch\"\n" ++
        "        | \"audio\"\n" ++
        "        | \"audioworklet\"\n" ++
        "        | \"document\"\n" ++
        "        | \"embed\"\n" ++
        "        | \"font\"\n" ++
        "        | \"frame\";\n" ++
        "}\n" ++
        "class C {\n" ++
        "    as(\n" ++
        "        value: string,\n" ++
        "    ): string | number | boolean | undefined | null | symbol | bigint | " ++
        "object {\n" ++
        "        return value;\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "a type assertion an export default holds takes parentheses" {
    const source_a = "export default <Environment>{\n" ++
        "\tname: 'x',\n" ++
        "\ttransformMode: 'web',\n" ++
        "};\n";

    const wanted_a = "export default (<Environment>{\n" ++
        "    name: \"x\",\n" ++
        "    transformMode: \"web\",\n" ++
        "});\n";

    const kept_b = "export default (<T>x);\n";

    const source_c = "export default <T>x.y;\n" ++
        "class A extends (<T>B) {}\n" ++
        "const t = (<T>x)`tpl`;\n";

    const wanted_c = "export default (<T>x.y);\n" ++
        "class A extends (<T>B) {}\n" ++
        "const t = (<T>x)`tpl`;\n";

    const kept_d = "export = <T>x;\n";

    try expect_formatted(source_a, wanted_a);
    try expect_formatted(wanted_a, wanted_a);
    try expect_formatted(kept_b, kept_b);
    try expect_formatted(source_c, wanted_c);
    try expect_formatted(wanted_c, wanted_c);
    try expect_formatted(kept_d, kept_d);
}

test "an import type in a union is a member, so the union breaks at its bars" {
    const source = "export type ClassValue = string | import('clsx').ClassArray | " ++
        "import('clsx').ClassDictionary;\n" ++
        "export type ClassValue2 = string | ClsxModule.ClassArrayxxxxxx | " ++
        "ClsxModule.ClassDictionaryxxxx;\n" ++
        "export type ClassValue3 = string | ClsxModuleeeee<ClassArrayyyyy> | " ++
        "ClsxModuleeeee<ClassDictionary>;\n" ++
        "export type ClassValue4 = string | (ClsxModuleeeee.ClassArrayyyyy) | " ++
        "(ClsxModuleeeee.ClassDictionary);\n" ++
        "export type ClassValue5 = string | typeof ClsxModuleeeee.ClassArrayyyy | " ++
        "typeof ClsxModule.ClassDict;\n" ++
        "export type ClassValue6 = import('clsx').ClassArray | string | " ++
        "import('clsx').ClassDictionaryxxxx;\n";

    const wanted = "export type ClassValue =\n" ++
        "    | string\n" ++
        "    | import(\"clsx\").ClassArray\n" ++
        "    | import(\"clsx\").ClassDictionary;\n" ++
        "export type ClassValue2 =\n" ++
        "    | string\n" ++
        "    | ClsxModule.ClassArrayxxxxxx\n" ++
        "    | ClsxModule.ClassDictionaryxxxx;\n" ++
        "export type ClassValue3 =\n" ++
        "    | string\n" ++
        "    | ClsxModuleeeee<ClassArrayyyyy>\n" ++
        "    | ClsxModuleeeee<ClassDictionary>;\n" ++
        "export type ClassValue4 =\n" ++
        "    | string\n" ++
        "    | ClsxModuleeeee.ClassArrayyyyy\n" ++
        "    | ClsxModuleeeee.ClassDictionary;\n" ++
        "export type ClassValue5 =\n" ++
        "    | string\n" ++
        "    | typeof ClsxModuleeeee.ClassArrayyyy\n" ++
        "    | typeof ClsxModule.ClassDict;\n" ++
        "export type ClassValue6 =\n" ++
        "    | import(\"clsx\").ClassArray\n" ++
        "    | string\n" ++
        "    | import(\"clsx\").ClassDictionaryxxxx;\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "an array cast in a for of head and a non-null object index drop their outer parentheses" {
    const source = "for (const modifier of (['Shift', 'Control', 'Alt', 'Meta']) as " ++
        "types.KeyboardModifier[]) {\n" ++
        "\tparts.push(modifier);\n" ++
        "}\n" ++
        "const f = (c) => ({ '&': '&amp;', '\"': '&quot;', '<': '&lt;', '>': '&gt;' " ++
        "}[c]!);\n" ++
        "const g = (c) => ({ a: 1 }[c]);\n" ++
        "const h = (c) => ({ a: 1 }).b;\n";

    const wanted = "for (const modifier of [\n" ++
        "    \"Shift\",\n" ++
        "    \"Control\",\n" ++
        "    \"Alt\",\n" ++
        "    \"Meta\",\n" ++
        "] as types.KeyboardModifier[]) {\n" ++
        "    parts.push(modifier);\n" ++
        "}\n" ++
        "const f = (c) => ({ \"&\": \"&amp;\", '\"': \"&quot;\", \"<\": \"&lt;\", " ++
        "\">\": \"&gt;\" })[c]!;\n" ++
        "const g = (c) => ({ a: 1 })[c];\n" ++
        "const h = (c) => ({ a: 1 }).b;\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "a signature breaks its parameters unless one plain parameter holds an object return" {
    const source = "interface I {\n" ++
        "\t(this: void, internals: ComponentInternals, props: Props): {\n" ++
        "\t\t$on?(type: string, callback: (e: any) => void): () => void;\n" ++
        "\t\t$set?(props: Partial<Props>): void;\n" ++
        "\t} & Exports;\n" ++
        "}\n" ++
        "declare function $inspect<T extends any[]>(...values: T): { with: (fn: " ++
        "(type: 'init' | 'update', ...values: T) => void) => void };\n" ++
        "class C {\n" ++
        "\ttoJointMappedObject<O = T>(transform: (value: T) => O): " ++
        "{[classPropertyName: string]: O} {\n" ++
        "\t\treturn 1;\n" ++
        "\t}\n" ++
        "}\n" ++
        "declare function inspect<T extends any[]>(...values: T): { with: (fn: " ++
        "(type: 'init' | 'update', ...values: T) => void) => void };\n";

    const wanted = "interface I {\n" ++
        "    (\n" ++
        "        this: void,\n" ++
        "        internals: ComponentInternals,\n" ++
        "        props: Props,\n" ++
        "    ): {\n" ++
        "        $on?(type: string, callback: (e: any) => void): () => void;\n" ++
        "        $set?(props: Partial<Props>): void;\n" ++
        "    } & Exports;\n" ++
        "}\n" ++
        "declare function $inspect<T extends any[]>(\n" ++
        "    ...values: T\n" ++
        "): { with: (fn: (type: \"init\" | \"update\", ...values: T) => void) => " ++
        "void };\n" ++
        "class C {\n" ++
        "    toJointMappedObject<O = T>(\n" ++
        "        transform: (value: T) => O,\n" ++
        "    ): { [classPropertyName: string]: O } {\n" ++
        "        return 1;\n" ++
        "    }\n" ++
        "}\n" ++
        "declare function inspect<T extends any[]>(\n" ++
        "    ...values: T\n" ++
        "): { with: (fn: (type: \"init\" | \"update\", ...values: T) => void) => " ++
        "void };\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "a function, an export, a type member and a static method break their parameters alike" {
    const source = "function inspect2<T extends any[]>(...values: T): { with: (fn: (type: " ++
        "'init' | 'update', ...values: T) => void) => void } { return 1; }\n" ++
        "export function inspect3<T extends any[]>(...values: T): { with: (fn: " ++
        "(type: 'init' | 'update', ...values: T) => void) => void };\n" ++
        "type S = {\n" ++
        "\tstore: Pick<{ add<T extends { dispose(): void }>(t: T): T }, 'add'>;\n" ++
        "};\n" ++
        "class M {\n" ++
        "\tstatic fromMappedObject<T extends InputOrOutput>(obj: " ++
        "{[classPropertyName: string]: BindingPropertyName | T}): " ++
        "ClassPropertyMapping<T> {\n" ++
        "\t\treturn 1;\n" ++
        "\t}\n" ++
        "}\n";

    const wanted = "function inspect2<T extends any[]>(\n" ++
        "    ...values: T\n" ++
        "): { with: (fn: (type: \"init\" | \"update\", ...values: T) => void) => " ++
        "void } {\n" ++
        "    return 1;\n" ++
        "}\n" ++
        "export function inspect3<T extends any[]>(\n" ++
        "    ...values: T\n" ++
        "): { with: (fn: (type: \"init\" | \"update\", ...values: T) => void) => " ++
        "void };\n" ++
        "type S = {\n" ++
        "    store: Pick<{ add<T extends { dispose(): void }>(t: T): T }, \"add\">;\n" ++
        "};\n" ++
        "class M {\n" ++
        "    static fromMappedObject<T extends InputOrOutput>(obj: {\n" ++
        "        [classPropertyName: string]: BindingPropertyName | T;\n" ++
        "    }): ClassPropertyMapping<T> {\n" ++
        "        return 1;\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "a binary operand of as or satisfies takes parentheses" {
    const source = "function f(ticks: number, ms: number) {\n" ++
        "\treturn (ticks + ms) as Ticks;\n" ++
        "}\n" ++
        "const a = (b || c) as D;\n" ++
        "const e = (f ?? g) satisfies H;\n" ++
        "const i = j + k as L;\n" ++
        "const m = (n === o) as boolean;\n";

    const wanted = "function f(ticks: number, ms: number) {\n" ++
        "    return (ticks + ms) as Ticks;\n" ++
        "}\n" ++
        "const a = (b || c) as D;\n" ++
        "const e = (f ?? g) satisfies H;\n" ++
        "const i = (j + k) as L;\n" ++
        "const m = (n === o) as boolean;\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "a return type angle breaks when its expanded content does not hug" {
    const source = "class C {\n" ++
        "  setLayout = (\n" ++
        "    layout: Layout<PropsForRenderer & { Layout: Layout }>\n" ++
        "  ): Layout<\n" ++
        "    PropsForRenderer & {\n" ++
        "      Layout: Layout\n" ++
        "    }\n" ++
        "  > => (this.#layout = layout)\n" ++
        "}\n" ++
        "const h = (a: A): Layout<B, {\n" ++
        "    L: L\n" ++
        "}> => a\n";

    const wanted = "class C {\n" ++
        "    setLayout = (\n" ++
        "        layout: Layout<PropsForRenderer & { Layout: Layout }>,\n" ++
        "    ): Layout<\n" ++
        "        PropsForRenderer & {\n" ++
        "            Layout: Layout;\n" ++
        "        }\n" ++
        "    > => (this.#layout = layout);\n" ++
        "}\n" ++
        "const h = (\n" ++
        "    a: A,\n" ++
        "): Layout<\n" ++
        "    B,\n" ++
        "    {\n" ++
        "        L: L;\n" ++
        "    }\n" ++
        "> => a;\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "an arrow body after a hugged parameter object takes the parameter line's level" {
    const source = "const jwt = (options: {\n" ++
        "  cookie?:\n" ++
        "    | string\n" ++
        "    | { key: string; secret?: string | BufferSource; prefixOptions?: " ++
        "CookiePrefixOptions }\n" ++
        "}) => {\n" ++
        "  const verifyOpts = options.verification || {}\n" ++
        "}\n";

    const wanted = "const jwt = (options: {\n" ++
        "    cookie?:\n" ++
        "        | string\n" ++
        "        | {\n" ++
        "              key: string;\n" ++
        "              secret?: string | BufferSource;\n" ++
        "              prefixOptions?: CookiePrefixOptions;\n" ++
        "          };\n" ++
        "}) => {\n" ++
        "    const verifyOpts = options.verification || {};\n" ++
        "};\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "a comment or an expanded object in arrow type parameters breaks the parameters" {
    const source = "const y = <\n" ++
        "  A,\n" ++
        "  // c\n" ++
        "  B,\n" ++
        ">(a: A) => a\n" ++
        "const z = <T extends {\n" ++
        "  a: 1\n" ++
        "}>(a: T) => a\n";

    const wanted = "const y = <\n" ++
        "    A,\n" ++
        "    // c\n" ++
        "    B,\n" ++
        ">(\n" ++
        "    a: A,\n" ++
        ") => a;\n" ++
        "const z = <\n" ++
        "    T extends {\n" ++
        "        a: 1;\n" ++
        "    },\n" ++
        ">(\n" ++
        "    a: T,\n" ++
        ") => a;\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "type parameters after class or function are no cast" {
    const source = "const R = class<T> extends RegExpRouter<T> {\n" ++
        "  m() {}\n" ++
        "}\n" ++
        "const S = function <T>(a: T) { return a }\n";

    const wanted = "const R = class<T> extends RegExpRouter<T> {\n" ++
        "    m() {}\n" ++
        "};\n" ++
        "const S = function <T>(a: T) {\n" ++
        "    return a;\n" ++
        "};\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "an expanded return type breaks the arrow parameters and keeps its union bars" {
    const source = "const g = (a: A): Layout<B | {\n" ++
        "    L: L\n" ++
        "}> => a\n" ++
        "const k = (a: A): Layout<{\n" ++
        "    L: L\n" ++
        "}> => a\n" ++
        "const m = (a: A, b: B): Layout<{\n" ++
        "    L: L\n" ++
        "}> => a\n";

    const wanted = "const g = (\n" ++
        "    a: A,\n" ++
        "): Layout<\n" ++
        "    | B\n" ++
        "    | {\n" ++
        "          L: L;\n" ++
        "      }\n" ++
        "> => a;\n" ++
        "const k = (\n" ++
        "    a: A,\n" ++
        "): Layout<{\n" ++
        "    L: L;\n" ++
        "}> => a;\n" ++
        "const m = (\n" ++
        "    a: A,\n" ++
        "    b: B,\n" ++
        "): Layout<{\n" ++
        "    L: L;\n" ++
        "}> => a;\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

const overload_member_source = "  // overload\n" ++
    "  <\n" ++
    "    P extends string = CurrentPath,\n" ++
    "    I extends Input = BlankInput,\n" ++
    "    R extends HandlerResponse<any> = any,\n" ++
    "    E2 extends Env = E,\n" ++
    "  >(\n" ++
    "    handler: H<E2, P, I, R>\n" ++
    "  ): HonoBase<IntersectNonAnyTypes<[E, E2]>, S & ToSchema<M, P, I, " ++
    "MergeTypedResponse<R>>, BasePath>\n";

const overload_member_wanted = "    // overload\n" ++
    "    <\n" ++
    "        P extends string = CurrentPath,\n" ++
    "        I extends Input = BlankInput,\n" ++
    "        R extends HandlerResponse<any> = any,\n" ++
    "        E2 extends Env = E,\n" ++
    "    >(\n" ++
    "        handler: H<E2, P, I, R>,\n" ++
    "    ): HonoBase<\n" ++
    "        IntersectNonAnyTypes<[E, E2]>,\n" ++
    "        S & ToSchema<M, P, I, MergeTypedResponse<R>>,\n" ++
    "        BasePath\n" ++
    "    >;\n";

test "a call signature deep in a long interface keeps its type parameter group" {
    const gpa = std.testing.allocator;
    const member_copies: u32 = 6;

    const source_last = "  // last\n" ++
        "  <\n" ++
        "    P extends string = CurrentPath,\n" ++
        "    R extends HandlerResponse<any> = any,\n" ++
        "    // Middleware\n" ++
        "    M1 extends H<E2, P, I> = H<E2, P, I>,\n" ++
        "  >(\n" ++
        "    ...handlers: [H<E2, P, I> & M1, H<E3, P, I2> & M2, H<E4, P, I3> & " ++
        "M3, H<E5, P, I4, R>]\n" ++
        "  ): HonoBase<IntersectNonAnyTypes<[E, E2, E3]>, BasePath, " ++
        "CurrentPath>\n";

    const wanted_last = "    // last\n" ++
        "    <\n" ++
        "        P extends string = CurrentPath,\n" ++
        "        R extends HandlerResponse<any> = any,\n" ++
        "        // Middleware\n" ++
        "        M1 extends H<E2, P, I> = H<E2, P, I>,\n" ++
        "    >(\n" ++
        "        ...handlers: [\n" ++
        "            H<E2, P, I> & M1,\n" ++
        "            H<E3, P, I2> & M2,\n" ++
        "            H<E4, P, I3> & M3,\n" ++
        "            H<E5, P, I4, R>,\n" ++
        "        ]\n" ++
        "    ): HonoBase<IntersectNonAnyTypes<[E, E2, E3]>, BasePath, " ++
        "CurrentPath>;\n";

    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(gpa);

    var wanted: std.ArrayList(u8) = .empty;
    defer wanted.deinit(gpa);

    try source.appendSlice(gpa, "interface X {\n");
    try wanted.appendSlice(gpa, "interface X {\n");

    for (0..member_copies) |index| {
        if (index > 0) {
            try source.appendSlice(gpa, "\n");
            try wanted.appendSlice(gpa, "\n");
        }

        try source.appendSlice(gpa, overload_member_source);
        try wanted.appendSlice(gpa, overload_member_wanted);
    }

    try source.appendSlice(gpa, "\n");
    try source.appendSlice(gpa, source_last);
    try source.appendSlice(gpa, "}\n");
    try wanted.appendSlice(gpa, "\n");
    try wanted.appendSlice(gpa, wanted_last);
    try wanted.appendSlice(gpa, "}\n");

    try expect_formatted(source.items, wanted.items);
    try expect_formatted(wanted.items, wanted.items);
}

test "a call signature after a comment or a line break is a signature member" {
    const source = "interface X {\n" ++
        "  <\n" ++
        "    P extends string = CurrentPath,\n" ++
        "    R extends HandlerResponse<any> = any,\n" ++
        "    M1 extends H<E2, P, I> = H<E2, P, I>,\n" ++
        "  >(\n" ++
        "    handler: H<E2, P, I, R>\n" ++
        "  ): HonoBase<IntersectNonAnyTypes<[E, E2]>, S & ToSchema<M, P, I, " ++
        "MergeTypedResponse<R>>, BasePath>\n" ++
        "\n" ++
        "  // app.get(handler x2)\n" ++
        "  <\n" ++
        "    P extends string = CurrentPath,\n" ++
        "    R extends HandlerResponse<any> = any,\n" ++
        "    M1 extends H<E2, P, I> = H<E2, P, I>,\n" ++
        "  >(\n" ++
        "    handler: H<E2, P, I, R>\n" ++
        "  ): HonoBase<IntersectNonAnyTypes<[E, E2]>, S & ToSchema<M, P, I, " ++
        "MergeTypedResponse<R>>, BasePath>\n" ++
        "}\n";

    const wanted = "interface X {\n" ++
        "    <\n" ++
        "        P extends string = CurrentPath,\n" ++
        "        R extends HandlerResponse<any> = any,\n" ++
        "        M1 extends H<E2, P, I> = H<E2, P, I>,\n" ++
        "    >(\n" ++
        "        handler: H<E2, P, I, R>,\n" ++
        "    ): HonoBase<\n" ++
        "        IntersectNonAnyTypes<[E, E2]>,\n" ++
        "        S & ToSchema<M, P, I, MergeTypedResponse<R>>,\n" ++
        "        BasePath\n" ++
        "    >;\n" ++
        "\n" ++
        "    // app.get(handler x2)\n" ++
        "    <\n" ++
        "        P extends string = CurrentPath,\n" ++
        "        R extends HandlerResponse<any> = any,\n" ++
        "        M1 extends H<E2, P, I> = H<E2, P, I>,\n" ++
        "    >(\n" ++
        "        handler: H<E2, P, I, R>,\n" ++
        "    ): HonoBase<\n" ++
        "        IntersectNonAnyTypes<[E, E2]>,\n" ++
        "        S & ToSchema<M, P, I, MergeTypedResponse<R>>,\n" ++
        "        BasePath\n" ++
        "    >;\n" ++
        "}\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "a call hugs from the line a broken type annotation leaves" {
    const source = "export const upgradeWebSocket: UpgradeWebSocket<WebSocket, " ++
        "Deno.UpgradeWebSocketOptions> =\n" ++
        "  defineWebSocketHelper(async (c, events, options) => {\n" ++
        "    const subprotocol = c.req.header(\"sec-websocket-protocol\")?.split(\"," ++
        "\")[0]?.trim()\n" ++
        "  })\n";

    const wanted = "export const upgradeWebSocket: UpgradeWebSocket<\n" ++
        "    WebSocket,\n" ++
        "    Deno.UpgradeWebSocketOptions\n" ++
        "> = defineWebSocketHelper(async (c, events, options) => {\n" ++
        "    const subprotocol = c.req.header(\"sec-websocket-protocol\")?.split(\"," ++
        "\")[0]?.trim();\n" ++
        "});\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "a blank line before a leading semicolon stays" {
    const source = "foo()\n" ++
        "\n" ++
        ";[a].forEach(x)\n" ++
        "bar()\n" ++
        ";[b].forEach(x)\n" ++
        "baz()\n" ++
        ";\n" ++
        "[c].forEach(x)\n" ++
        "qux()\n" ++
        "\n" ++
        ";\n" ++
        "[d].forEach(x)\n" ++
        "quux()\n" ++
        ";\n" ++
        "\n" ++
        "[e].forEach(x)\n";

    const wanted = "foo();\n" ++
        "\n" ++
        "[a].forEach(x);\n" ++
        "bar();\n" ++
        "[b].forEach(x);\n" ++
        "baz();\n" ++
        "[c].forEach(x);\n" ++
        "qux();\n" ++
        "\n" ++
        "[d].forEach(x);\n" ++
        "quux();\n" ++
        "\n" ++
        "[e].forEach(x);\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "a statement binary breaks at its operator around an expanded object" {
    const source = "function f() {\n" ++
        "  socket.onmessage &&\n" ++
        "    socket.onmessage(\n" ++
        "      new MessageEvent(\"message\", {\n" ++
        "        data,\n" ++
        "      })\n" ++
        "    )\n" ++
        "  a || b({\n" ++
        "    data\n" ++
        "  })\n" ++
        "  a || {\n" ++
        "    data\n" ++
        "  }\n" ++
        "  a && b(new C(\"message\", { data }))\n" ++
        "}\n";

    const wanted = "function f() {\n" ++
        "    socket.onmessage &&\n" ++
        "        socket.onmessage(\n" ++
        "            new MessageEvent(\"message\", {\n" ++
        "                data,\n" ++
        "            }),\n" ++
        "        );\n" ++
        "    a ||\n" ++
        "        b({\n" ++
        "            data,\n" ++
        "        });\n" ++
        "    a || {\n" ++
        "        data,\n" ++
        "    };\n" ++
        "    a && b(new C(\"message\", { data }));\n" ++
        "}\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "a type annotation is complex only when a whole argument is generic" {
    const source = "let blockingPromiseMap: Record<string, Promise<Event> | undefined> = " ++
        "Object.create(null)\n" ++
        "let blockingPromiseMapzzzzz: Record<string, Promise<Eventsssss>> = " ++
        "Object.create(nullish)\n" ++
        "let blockingPromiseMapzzzzz: Record<string, Promise<Eventsss>[]> = " ++
        "Object.create(nullish)\n" ++
        "let blockingPromiseMapx: Record<string, Map<Event, Ev>> = " ++
        "Object.create(nullishhhhhhhhhhhh)\n" ++
        "let blockingPromiseMapx: Record<string, Map<Event, Ev> & Foo> = " ++
        "Object.create(nullishhhh)\n";

    const wanted = "let blockingPromiseMap: Record<string, Promise<Event> | undefined> =\n" ++
        "    Object.create(null);\n" ++
        "let blockingPromiseMapzzzzz: Record<string, Promise<Eventsssss>> = " ++
        "Object.create(\n" ++
        "    nullish,\n" ++
        ");\n" ++
        "let blockingPromiseMapzzzzz: Record<string, Promise<Eventsss>[]> =\n" ++
        "    Object.create(nullish);\n" ++
        "let blockingPromiseMapx: Record<string, Map<Event, Ev>> = Object.create(\n" ++
        "    nullishhhhhhhhhhhh,\n" ++
        ");\n" ++
        "let blockingPromiseMapx: Record<string, Map<Event, Ev> & Foo> =\n" ++
        "    Object.create(nullishhhh);\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "an arrow body after a broken type annotation takes the declaration's level" {
    const source = "export const form: FC<\n" ++
        "  PropsWithChildren<{\n" ++
        "    ref?: RefObject<HTMLFormElement | null> | ((e: HTMLFormElement | null) " ++
        "=> void | (() => void))\n" ++
        "  }>\n" ++
        "> = (props) => {\n" ++
        "  const { action, ...restProps } = props\n" ++
        "}\n";

    const wanted = "export const form: FC<\n" ++
        "    PropsWithChildren<{\n" ++
        "        ref?:\n" ++
        "            | RefObject<HTMLFormElement | null>\n" ++
        "            | ((e: HTMLFormElement | null) => void | (() => void));\n" ++
        "    }>\n" ++
        "> = (props) => {\n" ++
        "    const { action, ...restProps } = props;\n" ++
        "};\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "a function type after broken type parameters measures from their close" {
    const source = "export type EventContext<Env = {}, P extends string = any, Data = " ++
        "Record<string, unknown>> = {\n" ++
        "  request: Request\n" ++
        "}\n" ++
        "type PagesFunction<\n" ++
        "  Env = unknown,\n" ++
        "  Params extends string = any,\n" ++
        "  Data extends Record<string, unknown> = Record<string, unknown>,\n" ++
        "> = (context: EventContext<Env, Params, Data>) => Response | " ++
        "Promise<Response>\n";

    const wanted = "export type EventContext<\n" ++
        "    Env = {},\n" ++
        "    P extends string = any,\n" ++
        "    Data = Record<string, unknown>,\n" ++
        "> = {\n" ++
        "    request: Request;\n" ++
        "};\n" ++
        "type PagesFunction<\n" ++
        "    Env = unknown,\n" ++
        "    Params extends string = any,\n" ++
        "    Data extends Record<string, unknown> = Record<string, unknown>,\n" ++
        "> = (context: EventContext<Env, Params, Data>) => Response | " ++
        "Promise<Response>;\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "an unnamed call signature breaks its parameters with its type parameters" {
    const source = "interface JSONRespond {\n" ++
        "  <\n" ++
        "    T extends JSONValue | {} | InvalidJSONValue,\n" ++
        "    U extends ContentfulStatusCode = ContentfulStatusCode,\n" ++
        "  >(\n" ++
        "    object: T,\n" ++
        "    status?: U,\n" ++
        "    headers?: HeaderRecord\n" ++
        "  ): JSONRespondReturn<T, U>\n" ++
        "  <\n" ++
        "    T extends JSONValue | {} | InvalidJSONValue,\n" ++
        "    U extends ContentfulStatusCode = ContentfulStatusCode,\n" ++
        "  >(\n" ++
        "    object: T,\n" ++
        "    init?: ResponseOrInit<U>\n" ++
        "  ): JSONRespondReturn<T, U>\n" ++
        "}\n";

    const wanted = "interface JSONRespond {\n" ++
        "    <\n" ++
        "        T extends JSONValue | {} | InvalidJSONValue,\n" ++
        "        U extends ContentfulStatusCode = ContentfulStatusCode,\n" ++
        "    >(\n" ++
        "        object: T,\n" ++
        "        status?: U,\n" ++
        "        headers?: HeaderRecord,\n" ++
        "    ): JSONRespondReturn<T, U>;\n" ++
        "    <\n" ++
        "        T extends JSONValue | {} | InvalidJSONValue,\n" ++
        "        U extends ContentfulStatusCode = ContentfulStatusCode,\n" ++
        "    >(\n" ++
        "        object: T,\n" ++
        "        init?: ResponseOrInit<U>,\n" ++
        "    ): JSONRespondReturn<T, U>;\n" ++
        "}\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "type parameters after function star are generic" {
    const source = "export const fetchRoutesContent = function* <\n" ++
        "  E extends Env = Env,\n" ++
        "  S extends Schema = {},\n" ++
        "  BasePath extends string = \"/\",\n" ++
        ">(\n" ++
        "  app: Hono<E, S, BasePath>,\n" ++
        "  beforeRequestHook?: BeforeRequestHook,\n" ++
        "): Generator<number> {\n" ++
        "  yield 1\n" ++
        "}\n" ++
        "export const f2 = function <\n" ++
        "  E extends Env = Env,\n" ++
        "  S extends Schema = {},\n" ++
        "  BasePath extends string = \"/\",\n" ++
        ">(\n" ++
        "  app: Hono<E, S, BasePath>,\n" ++
        "  beforeRequestHook?: BeforeRequestHook,\n" ++
        "): Generator<number> {\n" ++
        "  return 1\n" ++
        "}\n";

    const wanted = "export const fetchRoutesContent = function* <\n" ++
        "    E extends Env = Env,\n" ++
        "    S extends Schema = {},\n" ++
        "    BasePath extends string = \"/\",\n" ++
        ">(app: Hono<E, S, BasePath>, beforeRequestHook?: BeforeRequestHook): " ++
        "Generator<number> {\n" ++
        "    yield 1;\n" ++
        "};\n" ++
        "export const f2 = function <\n" ++
        "    E extends Env = Env,\n" ++
        "    S extends Schema = {},\n" ++
        "    BasePath extends string = \"/\",\n" ++
        ">(app: Hono<E, S, BasePath>, beforeRequestHook?: BeforeRequestHook): " ++
        "Generator<number> {\n" ++
        "    return 1;\n" ++
        "};\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "a sole hugged parameter expands when the return type forces a break" {
    const source = "interface CreateCssJsxDomObjectsType {\n" ++
        "  (args: {\n" ++
        "    id: Readonly<string>\n" ++
        "  }): readonly [\n" ++
        "    {\n" ++
        "      toString(this: CssClassName): string\n" ++
        "    },\n" ++
        "    FC<PropsWithChildren<void>>,\n" ++
        "  ]\n" ++
        "}\n" ++
        "interface J {\n" ++
        "  (args: {\n" ++
        "    id: Readonly<string>\n" ++
        "  }): R\n" ++
        "  m(args: {\n" ++
        "    id: Readonly<string>\n" ++
        "  }): R\n" ++
        "}\n" ++
        "function f(args: {\n" ++
        "  id: Readonly<string>\n" ++
        "}): R {}\n" ++
        "const l = ({ a }: A): Layout<{\n" ++
        "    L: L\n" ++
        "}> => a\n" ++
        "const l2 = (args: {\n" ++
        "  id: string\n" ++
        "}): Layout<{\n" ++
        "    L: L\n" ++
        "}> => a\n" ++
        "const l3 = ({ a }: A): Layout<{ L: L }> => a\n";

    const wanted = "interface CreateCssJsxDomObjectsType {\n" ++
        "    (args: {\n" ++
        "        id: Readonly<string>;\n" ++
        "    }): readonly [\n" ++
        "        {\n" ++
        "            toString(this: CssClassName): string;\n" ++
        "        },\n" ++
        "        FC<PropsWithChildren<void>>,\n" ++
        "    ];\n" ++
        "}\n" ++
        "interface J {\n" ++
        "    (args: { id: Readonly<string> }): R;\n" ++
        "    m(args: { id: Readonly<string> }): R;\n" ++
        "}\n" ++
        "function f(args: { id: Readonly<string> }): R {}\n" ++
        "const l = ({\n" ++
        "    a,\n" ++
        "}: A): Layout<{\n" ++
        "    L: L;\n" ++
        "}> => a;\n" ++
        "const l2 = (args: {\n" ++
        "    id: string;\n" ++
        "}): Layout<{\n" ++
        "    L: L;\n" ++
        "}> => a;\n" ++
        "const l3 = ({ a }: A): Layout<{ L: L }> => a;\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "a multi-line comment after the equals breaks before a flat union" {
    const source = "type A3 = /**\n" ++
        "     * octahedral\n" ++
        "     */\n" ++
        "    a | (b | c);\n" ++
        "type A0 = /* comment */\n" ++
        "    | B\n" ++
        "    | C;\n" ++
        "type A2 = /** doc */ B | C;\n";

    const wanted = "type A3 =\n" ++
        "    /**\n" ++
        "     * octahedral\n" ++
        "     */\n" ++
        "    a | (b | c);\n" ++
        "type A0 = /* comment */ B | C;\n" ++
        "type A2 = /** doc */ B | C;\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "a comment-led return argument keeps its parenthesis on the return line" {
    const source = "function conditional() {\n" ++
        "    return (\n" ++
        "        // Reason for 42\n" ++
        "        42\n" ++
        "    ) ? 1 : 2;\n" ++
        "}\n" ++
        "function blockSameLine() {\n" ++
        "    return (\n" ++
        "        /** Result -> */ \"result\"\n" ++
        "    );\n" ++
        "}\n";

    const wanted = "function conditional() {\n" ++
        "    return ( // Reason for 42\n" ++
        "        42 ? 1 : 2);\n" ++
        "}\n" ++
        "function blockSameLine() {\n" ++
        "    return (\n" ++
        "        /** Result -> */ \"result\"\n" ++
        "    );\n" ++
        "}\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "a type literal's last semicolon takes no width in a union" {
    const source = "var unionOfDifferentReturnTypeABCDEFGHIJKLMNO: { aaaaaaa: number; } | { " ++
        "bbbbbbbb: Date; };\n" ++
        "var unionOfDifferentReturnTypeABCDEFGHIJKL: { aaaaaaa(): number; } | { " ++
        "bbbbbbbb(): Date; };\n";

    const wanted = "var unionOfDifferentReturnTypeABCDEFGHIJKLMNO: { aaaaaaa: number } | { " ++
        "bbbbbbbb: Date };\n" ++
        "var unionOfDifferentReturnTypeABCDEFGHIJKL:\n" ++
        "    | { aaaaaaa(): number }\n" ++
        "    | { bbbbbbbb(): Date };\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "a lone union member takes no parentheses" {
    const source = "type E1 = | a & b;\n" ++
        "type E3 = | a & (| b);\n" ++
        "type E4 = | (a & b);\n" ++
        "type E5 = (| a & b);\n" ++
        "type C3 = /*1*/ | a & (| b);\n" ++
        "type D3 = /*1*/ & a | (& b);\n" ++
        "type D4 = /*1*/ & (a | b);\n" ++
        "type X = A | B & C;\n" ++
        "let w: | B & C | D;\n";

    const wanted = "type E1 = a & b;\n" ++
        "type E3 = a & b;\n" ++
        "type E4 = a & b;\n" ++
        "type E5 = a & b;\n" ++
        "type C3 = /*1*/ a & b;\n" ++
        "type D3 = /*1*/ a | b;\n" ++
        "type D4 = /*1*/ a | b;\n" ++
        "type X = A | (B & C);\n" ++
        "let w: (B & C) | D;\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "a sole arrow parameter drops a trailing comma written before the line break" {
    const source = "const a4 = ({ size }: P,\n" ++
        ") => {};\n" ++
        "const a5 = ({ size },\n" ++
        ") => {};\n" ++
        "type F1 = (a: T,\n" ++
        ") => R;\n" ++
        "const foo = f(({\n" ++
        "    // foo\n" ++
        "    size,\n" ++
        "}: P,\n" ++
        ") => {});\n";

    const wanted = "const a4 = ({ size }: P) => {};\n" ++
        "const a5 = ({ size }) => {};\n" ++
        "type F1 = (a: T) => R;\n" ++
        "const foo = f(\n" ++
        "    ({\n" ++
        "        // foo\n" ++
        "        size,\n" ++
        "    }: P) => {},\n" ++
        ");\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "a parenthesized tuple element is no call signature" {
    const source = "type D = [\n" ++
        "  (AAAAAAAAAAAAAAAAAAAAAA | BBBBBBBBBBBBBBBBBBBBBB | CCCCCCCCCCCCCCCCCCCCCC " ++
        "| DDDDDDDDDDDDDDDDDDDDDD),\n" ++
        "  (AAAAAAAAAAAAAAAAAAAAAA | BBBBBBBBBBBBBBBBBBBBBB | CCCCCCCCCCCCCCCCCCCCCC " ++
        "| DDDDDDDDDDDDDDDDDDDDDD)\n" ++
        "]\n" ++
        "type F = [(a: number) => void, (b: string) => void];\n" ++
        "type G = [\n" ++
        "  (aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa: number) => void,\n" ++
        "  (bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb: string, cccccccccccccccccc: " ++
        "number) => void\n" ++
        "];\n";

    const wanted = "type D = [\n" ++
        "    (\n" ++
        "        | AAAAAAAAAAAAAAAAAAAAAA\n" ++
        "        | BBBBBBBBBBBBBBBBBBBBBB\n" ++
        "        | CCCCCCCCCCCCCCCCCCCCCC\n" ++
        "        | DDDDDDDDDDDDDDDDDDDDDD\n" ++
        "    ),\n" ++
        "    (\n" ++
        "        | AAAAAAAAAAAAAAAAAAAAAA\n" ++
        "        | BBBBBBBBBBBBBBBBBBBBBB\n" ++
        "        | CCCCCCCCCCCCCCCCCCCCCC\n" ++
        "        | DDDDDDDDDDDDDDDDDDDDDD\n" ++
        "    ),\n" ++
        "];\n" ++
        "type F = [(a: number) => void, (b: string) => void];\n" ++
        "type G = [\n" ++
        "    (aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa: number) => void,\n" ++
        "    (\n" ++
        "        bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb: string,\n" ++
        "        cccccccccccccccccc: number,\n" ++
        "    ) => void,\n" ++
        "];\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "a type literal inside a hugged pattern's generic annotation spreads" {
    const source = "const f = ({ a }: Partial<{ a: string }>) => a;\n" ++
        "function g({ a, b }: Readonly<{ aaaaaaaaaaaaaaaaaaaa: string; " ++
        "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb: number }>) {}\n" ++
        "class C {\n" ++
        "    m({ providerId, clientId, authorizationServer, label }: Partial<{ " ++
        "providerId: string; clientId: string; authorizationServer: UriComponents " ++
        "}>): Promise<void> {\n" ++
        "        return;\n" ++
        "    }\n" ++
        "}\n";

    const wanted = "const f = ({ a }: Partial<{ a: string }>) => a;\n" ++
        "function g({\n" ++
        "    a,\n" ++
        "    b,\n" ++
        "}: Readonly<{\n" ++
        "    aaaaaaaaaaaaaaaaaaaa: string;\n" ++
        "    bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb: number;\n" ++
        "}>) {}\n" ++
        "class C {\n" ++
        "    m({\n" ++
        "        providerId,\n" ++
        "        clientId,\n" ++
        "        authorizationServer,\n" ++
        "        label,\n" ++
        "    }: Partial<{\n" ++
        "        providerId: string;\n" ++
        "        clientId: string;\n" ++
        "        authorizationServer: UriComponents;\n" ++
        "    }>): Promise<void> {\n" ++
        "        return;\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "a comparison whose operand ends in an expanded object argument stays on the closing line" {
    const source = "function f() {\n" ++
        "  if (\n" ++
        "    typeof reducer(undefined, {\n" ++
        "      type: ActionTypes.PROBE_UNKNOWN_ACTION()\n" ++
        "    }) === \"undefined\"\n" ++
        "  ) {\n" ++
        "    throw new Error(\"x\");\n" ++
        "  }\n" ++
        "}\n";

    const wanted = "function f() {\n" ++
        "    if (\n" ++
        "        typeof reducer(undefined, {\n" ++
        "            type: ActionTypes.PROBE_UNKNOWN_ACTION(),\n" ++
        "        }) === \"undefined\"\n" ++
        "    ) {\n" ++
        "        throw new Error(\"x\");\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "an import type's attribute object keeps its commas" {
    const source = "type A = import(\"foo\", { with: { type: \"json\", mode: \"x\" } });\n" ++
        "type B = typeof import(\"./a/very/long/long/long/long/long/long/long/path/to" ++
        "/module\", { with: { type: \"json\" } });\n";

    const wanted = "type A = import(\"foo\", { with: { type: \"json\", mode: \"x\" } });\n" ++
        "type B = typeof import(\"./a/very/long/long/long/long/long/long/long/path/to" ++
        "/module\", {\n" ++
        "    with: { type: \"json\" },\n" ++
        "});\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "an object that leads a statement through a chain keeps parentheses" {
    const source = "({ a }.b());\n" ++
        "({ a }.b())!.c();\n" ++
        "if (a) ({ a }.b());\n" ++
        "if (a) ({ a, ...b }.a())!.c();\n" ++
        "while (a) ({ a }).b;\n";

    const wanted = "({ a }).b();\n" ++
        "({ a }).b()!.c();\n" ++
        "if (a) ({ a }).b();\n" ++
        "if (a) ({ a, ...b }).a()!.c();\n" ++
        "while (a) ({ a }).b;\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "a type literal a return type holds is no function body" {
    const source = "function lookup(url: string, method: string, headers: HeadersArray, " ++
        "postData: Buffer | undefined, isNavigationRequest: boolean): Wrap<{\n" ++
        "    action: string,\n" ++
        "    message?: string\n" ++
        "  }> {}\n" ++
        "class A {\n" ++
        "  _resolveOptions(): { outputFolder: string, open: HtmlReportOpenOption, " ++
        "attachmentsBaseURL: string, host: string | undefined } {\n" ++
        "    return x;\n" ++
        "  }\n" ++
        "}\n";

    const wanted = "function lookup(\n" ++
        "    url: string,\n" ++
        "    method: string,\n" ++
        "    headers: HeadersArray,\n" ++
        "    postData: Buffer | undefined,\n" ++
        "    isNavigationRequest: boolean,\n" ++
        "): Wrap<{\n" ++
        "    action: string;\n" ++
        "    message?: string;\n" ++
        "}> {}\n" ++
        "class A {\n" ++
        "    _resolveOptions(): {\n" ++
        "        outputFolder: string;\n" ++
        "        open: HtmlReportOpenOption;\n" ++
        "        attachmentsBaseURL: string;\n" ++
        "        host: string | undefined;\n" ++
        "    } {\n" ++
        "        return x;\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "a defaulted parameter's type literal is no destructuring pattern" {
    const source = "async function storageState(options: { path?: string, indexedDB?: boolean, " ++
        "opfs?: boolean } = {}): Promise<StorageState> {\n" ++
        "    return state;\n" ++
        "}\n";

    const wanted = "async function storageState(\n" ++
        "    options: { path?: string; indexedDB?: boolean; opfs?: boolean } = {},\n" ++
        "): Promise<StorageState> {\n" ++
        "    return state;\n" ++
        "}\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "a chain an if without braces holds indents its links past the statement" {
    const source = "function f() {\n" ++
        "  if (condition) someObject.methodNumberOne().methodNumberTwo()" ++
        ".methodNumberThree().methodNumberFour();\n" ++
        "  if (condition)\n" ++
        "    this.someObject.methodNumberOne().methodNumberTwo().methodNumberThree()" ++
        ".methodFour();\n" ++
        "}\n";

    const wanted = "function f() {\n" ++
        "    if (condition)\n" ++
        "        someObject\n" ++
        "            .methodNumberOne()\n" ++
        "            .methodNumberTwo()\n" ++
        "            .methodNumberThree()\n" ++
        "            .methodNumberFour();\n" ++
        "    if (condition)\n" ++
        "        this.someObject\n" ++
        "            .methodNumberOne()\n" ++
        "            .methodNumberTwo()\n" ++
        "            .methodNumberThree()\n" ++
        "            .methodFour();\n" ++
        "}\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "parentheses before as or satisfies keep a line comment off the operator's line" {
    const source = "(1 // comment\n" ++
        ") as const;\n" ++
        "const v = (x // c\n" ++
        ") satisfies T;\n";

    try expect_formatted(source, source);
}

test "a closing angle takes a space before the equals sign or the brace that follows it" {
    const source = "type X<T>=T[];\n" ++
        "let x: A<B>=y;\n" ++
        "function f(p: A<B>= q, r?: C<D>= s): Promise<A>{\n" ++
        "  return a;\n" ++
        "}\n" ++
        "const g = (): A<B<C>>=> x;\n" ++
        "class K extends A<B>{\n" ++
        "  static z: Map<K, V>=new Map();\n" ++
        "}\n";

    const wanted = "type X<T> = T[];\n" ++
        "let x: A<B> = y;\n" ++
        "function f(p: A<B> = q, r?: C<D> = s): Promise<A> {\n" ++
        "    return a;\n" ++
        "}\n" ++
        "const g = (): A<B<C>> => x;\n" ++
        "class K extends A<B> {\n" ++
        "    static z: Map<K, V> = new Map();\n" ++
        "}\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "a for await header heads its body the way a for header does" {
    const source = "async function f() {\n" ++
        "  for await (const chunk of stream)\n" ++
        "    result += chunk;\n" ++
        "  for await (const chunk of stream) {\n" ++
        "    result += chunk;\n" ++
        "  }\n" ++
        "  for await (const [metadata, sdkObject] of " ++
        "this._currentCallsMetadataOfTheRecorderInstance)\n" ++
        "    result += chunk;\n" ++
        "}\n";

    const wanted = "async function f() {\n" ++
        "    for await (const chunk of stream) result += chunk;\n" ++
        "    for await (const chunk of stream) {\n" ++
        "        result += chunk;\n" ++
        "    }\n" ++
        "    for await (const [metadata, sdkObject] of this\n" ++
        "        ._currentCallsMetadataOfTheRecorderInstance)\n" ++
        "        result += chunk;\n" ++
        "}\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "an assignment an if without braces holds measures from its own line" {
    const source = "function f() {\n" ++
        "  if (!extraOptions.headless)\n" ++
        "    contextOptions.deviceScaleFactor = os.platform() === \"darwin\" ? 2 : 1;\n" ++
        "}\n";

    const wanted = "function f() {\n" ++
        "    if (!extraOptions.headless)\n" ++
        "        contextOptions.deviceScaleFactor = os.platform() === \"darwin\" ? 2 : 1;\n" ++
        "}\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "a template assigned under an if without braces stays on the operator's line" {
    const source = "class A {\n" ++
        "  constructor(selector: string) {\n" ++
        "    if (options?.hasText)\n" ++
        "      selector += ` >> internal:has-text=" ++
        "${escapeForTextSelector(options.hasText, false)}`;\n" ++
        "  }\n" ++
        "}\n";

    const wanted = "class A {\n" ++
        "    constructor(selector: string) {\n" ++
        "        if (options?.hasText)\n" ++
        "            selector += ` >> internal:has-text=" ++
        "${escapeForTextSelector(options.hasText, false)}`;\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "a chain an if without braces leads with parentheses measures from its own line" {
    const source = "class A {\n" ++
        "  m(event: string, enabled: boolean) {\n" ++
        "    if (protocolEvent)\n" ++
        "      (this._channel as any).updateSubscription({ event: protocolEvent, enabled })" ++
        ".catch(() => {});\n" ++
        "    if (this._jsCoverageActive)\n" ++
        "      (this._page.coverage as CRCoverage).stopJSCoverage().catch(() => {});\n" ++
        "  }\n" ++
        "}\n";

    const wanted = "class A {\n" ++
        "    m(event: string, enabled: boolean) {\n" ++
        "        if (protocolEvent)\n" ++
        "            (this._channel as any)\n" ++
        "                .updateSubscription({ event: protocolEvent, enabled })\n" ++
        "                .catch(() => {});\n" ++
        "        if (this._jsCoverageActive)\n" ++
        "            (this._page.coverage as CRCoverage).stopJSCoverage().catch(() => {});\n" ++
        "    }\n" ++
        "}\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "a non-null assertion keeps a short chain poorly breakable" {
    const source = "function f() {\n" ++
        "    if (a) {\n" ++
        "        if (b) {\n" ++
        "            if (c) {\n" ++
        "                if (d) {\n" ++
        "                    const depsForBlock = analysis.explicitlyDeferredTypesByBlock!" ++
        ".get(blockName);\n" ++
        "                    const depsForBlock = analysis!.explicitlyDeferredTypesByBlock" ++
        ".get(blockName);\n" ++
        "                }\n" ++
        "            }\n" ++
        "        }\n" ++
        "    }\n" ++
        "    const nodeToProjectOrRNodes = componentNode.projection!" ++
        "[tProjectionNode.projection]!;\n" ++
        "}\n";

    const wanted = "function f() {\n" ++
        "    if (a) {\n" ++
        "        if (b) {\n" ++
        "            if (c) {\n" ++
        "                if (d) {\n" ++
        "                    const depsForBlock =\n" ++
        "                        analysis.explicitlyDeferredTypesByBlock!.get(blockName);\n" ++
        "                    const depsForBlock =\n" ++
        "                        analysis!.explicitlyDeferredTypesByBlock.get(blockName);\n" ++
        "                }\n" ++
        "            }\n" ++
        "        }\n" ++
        "    }\n" ++
        "    const nodeToProjectOrRNodes =\n" ++
        "        componentNode.projection![tProjectionNode.projection]!;\n" ++
        "}\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "a jsx attribute holding a conditional or a cast breaks inside its braces" {
    const source = "const a = <A setExpanded={setFileExpandedddddd ? (expanded) => " ++
        "setFileExpanded(file.fileId, expanded) : undefined} />;\n" ++
        "const b = <div style={{ ...style, \"--annotation-color\": a.color, " ++
        "\"--another-property\": b.color } as React.CSSProperties} />;\n";

    const wanted = "const a = (\n" ++
        "    <A\n" ++
        "        setExpanded={\n" ++
        "            setFileExpandedddddd\n" ++
        "                ? (expanded) => setFileExpanded(file.fileId, expanded)\n" ++
        "                : undefined\n" ++
        "        }\n" ++
        "    />\n" ++
        ");\n" ++
        "const b = (\n" ++
        "    <div\n" ++
        "        style={\n" ++
        "            {\n" ++
        "                ...style,\n" ++
        "                \"--annotation-color\": a.color,\n" ++
        "                \"--another-property\": b.color,\n" ++
        "            } as React.CSSProperties\n" ++
        "        }\n" ++
        "    />\n" ++
        ");\n";

    try expect_formatted_tsx(source, wanted);
    try expect_formatted_tsx(wanted, wanted);
}

test "a jsx element on one line is measured by the text it prints" {
    const source = "function f() {\n" ++
        "    if (!frameSrc) return <div className=\"screencast-placeholder\">" ++
        "Connecting...</div>;\n" ++
        "    return x;\n" ++
        "}\n";

    try expect_formatted_tsx(source, source);
}

test "a return type's flat type literal drops the separator written before its brace" {
    const source = "function f(nestedRanges: {\n" ++
        "  startOffset: number;\n" ++
        "  count: number; }[]): { start: number; end: number; }[] {\n" ++
        "  return x;\n" ++
        "}\n" ++
        "function g(a: string): { start: number; end: number; }[] {\n" ++
        "  return x;\n" ++
        "}\n";

    const wanted = "function f(\n" ++
        "    nestedRanges: {\n" ++
        "        startOffset: number;\n" ++
        "        count: number;\n" ++
        "    }[],\n" ++
        "): { start: number; end: number }[] {\n" ++
        "    return x;\n" ++
        "}\n" ++
        "function g(a: string): { start: number; end: number }[] {\n" ++
        "    return x;\n" ++
        "}\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "a curried arrow chain ends past the template holes its body holds" {
    const source = "function createSmallTabs(children: number) {\n" ++
        "  return defineComponent({\n" ++
        "    setup: () => () =>\n" ++
        "      h(SmallTabs, null, {\n" ++
        "        default: () =>\n" ++
        "          Array.from({ length: children }, (_, i) =>\n" ++
        "            h(SmallTabsPane, { title: `title-${i}` }, () => " ++
        "`content-${i}`),\n" ++
        "          ),\n" ++
        "      }),\n" ++
        "  })\n" ++
        "}\n";

    const wanted = "function createSmallTabs(children: number) {\n" ++
        "    return defineComponent({\n" ++
        "        setup: () => () =>\n" ++
        "            h(SmallTabs, null, {\n" ++
        "                default: () =>\n" ++
        "                    Array.from({ length: children }, (_, i) =>\n" ++
        "                        h(SmallTabsPane, { title: `title-${i}` }, () => " ++
        "`content-${i}`),\n" ++
        "                    ),\n" ++
        "            }),\n" ++
        "    });\n" ++
        "}\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "an assigned conditional measures its forced head after broken type parameters" {
    const source = "export type CoverageReporterWithOptions<ReporterName extends " ++
        "CoverageReporter = CoverageReporter> =\n" ++
        "  ReporterName extends keyof ReportOptions\n" ++
        "    ? [ReporterName, object] // E.g. the \"none\" reporter\n" ++
        "    : [ReporterName, Record<string, unknown>]\n";

    const wanted = "export type CoverageReporterWithOptions<\n" ++
        "    ReporterName extends CoverageReporter = CoverageReporter,\n" ++
        "> = ReporterName extends keyof ReportOptions\n" ++
        "    ? [ReporterName, object] // E.g. the \"none\" reporter\n" ++
        "    : [ReporterName, Record<string, unknown>];\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "a union in a conditional branch joins the source breaks before its bars" {
    const kept = "type F<T> = A extends B\n" ++
        "    ? C\n" ++
        "    :\n" ++
        "          | T[K]\n" ++
        "          | (T[K] extends any\n" ++
        "                ? FixtureFn<T, K, Omit<ExtraContext, Exclude<keyof T, " ++
        "K>>, MoreMoreMore>\n" ++
        "                : never);\n";

    const source = "type F<T> = A extends B\n" ++
        "    ? C\n" ++
        "    :\n" ++
        "          | D\n" ++
        "          | (E extends F ? G : H);\n";

    const wanted = "type F<T> = A extends B ? C : D | (E extends F ? G : H);\n";

    try expect_formatted(kept, kept);
    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "a block comment before a template value keeps it on the key's line" {
    const source = "const files = {\n" ++
        "  \"basic.test.ts\": /* ts */ `\n" ++
        "    test(\"x\", () => {})\n" ++
        "  `,\n" ++
        "  \"other.ts\": `\n" ++
        "    plain\n" ++
        "  `,\n" ++
        "}\n";

    const wanted = "const files = {\n" ++
        "    \"basic.test.ts\": /* ts */ `\n" ++
        "    test(\"x\", () => {})\n" ++
        "  `,\n" ++
        "    \"other.ts\": `\n" ++
        "    plain\n" ++
        "  `,\n" ++
        "};\n";

    try expect_formatted(source, wanted);
    try expect_formatted(wanted, wanted);
}

test "a default import named like a declaration word heads no body" {
    const kept = "import module, { createRequire, isBuiltin } from \"node:module\";\n" ++
        "import namespace, { a } from \"x\";\n";

    try expect_formatted(kept, kept);
}
