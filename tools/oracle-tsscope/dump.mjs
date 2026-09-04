// Dumps the scope tree @typescript-eslint/scope-manager builds for every source
// under a root, one JSON per file, in the row shape oracle-gotypes writes: an
// identifier's offset, its kind, its name, and the offset of the definition it
// resolves to. A row whose definition equals its own offset IS the definition;
// a row whose definition is -1 resolved to nothing the file declares.
//
// The scope manager is the model ESLint's own no-unused-vars, no-undef and
// no-redeclare are computed from, so it answers the same question the oxlint
// oracle answers, one layer lower and for every identifier rather than for the
// few a rule happens to report.

import fs from 'node:fs'
import path from 'node:path'

const EXTENSIONS = new Set(['.cjs', '.cts', '.js', '.mjs', '.mts', '.ts', '.tsx'])
const SKIPPED = new Set(['.git', 'node_modules'])

const DEFINITION_KIND = {
    CatchClause: 'Catch',
    ClassName: 'Class',
    FunctionName: 'Function',
    ImplicitGlobalVariable: 'Implicit',
    ImportBinding: 'Import',
    Parameter: 'Parameter',
    TSEnumMember: 'EnumMember',
    TSEnumName: 'Enum',
    TSModuleName: 'Module',
    Type: 'Type',
    Variable: 'Variable',
}

const sources = (root) => {
    const found = []
    const pending = [root]

    while (pending.length > 0) {
        const directory = pending.pop()

        let entries

        try {
            entries = fs.readdirSync(directory, { withFileTypes: true })
        } catch {
            continue
        }

        for (const entry of entries) {
            if (SKIPPED.has(entry.name)) {
                continue
            }

            const full = path.join(directory, entry.name)

            if (entry.isDirectory()) {
                pending.push(full)
            } else if (EXTENSIONS.has(path.extname(entry.name))) {
                found.push(full)
            }
        }
    }

    found.sort()

    return found
}

// Every range the parser reports counts UTF-16 code units, the way a JavaScript
// string is indexed. scylla counts bytes, so a file holding one non-ASCII
// character shifts every offset after it and the two models stop lining up.
// An all-ASCII file needs no map, which is nearly every file.
const bytes_of = (source) => {
    if (Buffer.byteLength(source, 'utf8') === source.length) {
        return null
    }

    const held = new Int32Array(source.length + 1)
    let bytes = 0
    let index = 0

    while (index < source.length) {
        held[index] = bytes

        const code = source.charCodeAt(index)

        if (code >= 0xd800 && code <= 0xdbff && index + 1 < source.length) {
            bytes += 4
            index += 1
            held[index] = bytes
        } else if (code < 0x80) {
            bytes += 1
        } else if (code < 0x800) {
            bytes += 2
        } else {
            bytes += 3
        }

        index += 1
    }

    held[source.length] = bytes

    return held
}

const kind_of = (variable) => {
    const held = variable.defs.length > 0 ? variable.defs[0].type : 'Implicit'

    return DEFINITION_KIND[held] ?? held
}

const role_of = (reference) => {
    if (reference.isWrite()) {
        return reference.isRead() ? 'ReadWrite' : 'Write'
    }

    return 'Read'
}

// A parameter written in a type-level signature -- a call signature, a method
// signature, a function type, an overload or an ambient declaration -- names a
// position rather than declaring a value. It is marked so a reader that models
// the value space alone can tell those rows apart from real parameters.
const SIGNATURE_NODE = new Set([
    'TSCallSignatureDeclaration',
    'TSConstructSignatureDeclaration',
    'TSConstructorType',
    'TSDeclareFunction',
    'TSEmptyBodyFunctionExpression',
    'TSFunctionType',
    'TSMethodSignature',
])

const signature_parameter = (held) =>
    held.type === 'Parameter' && held.node !== undefined && SIGNATURE_NODE.has(held.node.type)

// `const` in `x as const` and `this` in `function (this: T)` are reserved words
// standing where ESTree wants an identifier node. Neither can be renamed,
// shadowed or reached by another name, so a row for either describes the shape
// of the tree rather than a binding of the language.
const RESERVED = new Set(['const', 'this'])

// A reference standing on its own definition (`const x = 1` writes `x` where it
// declares it) is one identifier, so the definition row wins and the reference
// row is dropped. Every other offset carries exactly one row.
const rows_of = (manager, map) => {
    const at = (offset) => (map === null ? offset : map[offset])
    const rows = new Map()

    for (const scope of manager.scopes) {
        for (const variable of scope.variables) {
            const kind = kind_of(variable)

            for (const held of variable.defs) {
                if (RESERVED.has(variable.name)) {
                    continue
                }

                const offset = at(held.name.range[0])
                const named = signature_parameter(held) ? 'Signature' : kind

                rows.set(offset, [offset, named, variable.name, offset])
            }
        }
    }

    for (const scope of manager.scopes) {
        for (const reference of scope.references) {
            const offset = at(reference.identifier.range[0])

            if (rows.has(offset)) {
                continue
            }

            if (RESERVED.has(reference.identifier.name)) {
                continue
            }

            const resolved = reference.resolved
            const held = resolved && resolved.defs.length > 0 ? resolved.defs[0] : null
            const definition = held === null ? -1 : at(held.name.range[0])
            const named = held !== null && signature_parameter(held) ? 'Signature' : role_of(reference)

            rows.set(offset, [offset, named, reference.identifier.name, definition])
        }
    }

    return [...rows.values()].sort((left, right) => left[0] - right[0] || (left[2] < right[2] ? -1 : 1))
}

const render = (relative, rows, broken) => {
    const head = broken ? '{"broken":true,"ast":[' : '{"ast":['

    const body = rows
        .map(([offset, kind, name, definition]) =>
            `[${offset},${JSON.stringify(kind)},${JSON.stringify(name)},${definition}]`,
        )
        .join(',')

    return `${head}${body}],"path":${JSON.stringify(relative)}}\n`
}

const main = async () => {
    if (process.argv.length !== 4) {
        process.stderr.write('usage: dump.mjs <source-root> <destination>\n')

        return 2
    }

    const { parseForESLint } = await import('@typescript-eslint/parser')

    const root = path.resolve(process.argv[2])
    const destination = path.resolve(process.argv[3])
    const found = sources(root)

    if (found.length === 0) {
        process.stderr.write(`no sources under ${root}\n`)

        return 1
    }

    let written = 0

    for (const file of found) {
        const relative = path.relative(root, file).split(path.sep).join('/')
        const target = path.join(destination, `${relative}.json`)

        let rows = []
        let broken = false

        try {
            const source = fs.readFileSync(file, 'utf8')

            const held = parseForESLint(source, {
                range: true,
                loc: false,
                sourceType: 'module',
                ecmaFeatures: { jsx: file.endsWith('.tsx') || file.endsWith('.jsx') },
            })

            rows = rows_of(held.scopeManager, bytes_of(source))
        } catch {
            broken = true
        }

        fs.mkdirSync(path.dirname(target), { recursive: true })
        fs.writeFileSync(target, render(relative, rows, broken))

        written += 1
    }

    process.stderr.write(`wrote ${written} files\n`)

    return 0
}

process.exitCode = await main()
