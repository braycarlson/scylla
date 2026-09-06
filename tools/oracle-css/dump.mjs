import postcss from 'postcss';
import { mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { dirname, join, relative, sep } from 'node:path';

const VERSION = readFileSync(new URL('./PIN', import.meta.url), 'utf8').trim();

function byteOffset(source, offset) {
    return Buffer.byteLength(source.slice(0, offset), 'utf8');
}

function valuesOf(text, base) {
    const found = [];
    let offset = 0;

    while (offset < text.length) {
        const byte = text[offset];

        if (byte === ' ' || byte === '\t' || byte === '\n' || byte === '\r' || byte === ',') {
            offset += 1;

            continue;
        }

        if (byte === '"' || byte === "'") {
            let end = offset + 1;

            while (end < text.length && text[end] !== byte) {
                end += text[end] === '\\' ? 2 : 1;
            }

            found.push({ name: text.slice(offset + 1, end), offset: base + offset + 1 });
            offset = end + 1;

            continue;
        }

        let end = offset;

        while (end < text.length && !' \t\n\r,('.includes(text[end])) {
            end += 1;
        }

        if (text[end] === '(') {
            let depth = 0;

            while (end < text.length) {
                if (text[end] === '(') depth += 1;
                if (text[end] === ')') {
                    depth -= 1;

                    if (depth === 0) {
                        end += 1;

                        break;
                    }
                }

                end += 1;
            }

            offset = end;

            continue;
        }

        const name = text.slice(offset, end);

        const numeric = /^[+-]?(\d+\.?\d*|\.\d+)$/.test(name);

        if (end > offset && text[offset] !== '!' && !numeric) {
            found.push({ name, offset: base + offset });
        }

        offset = end;
    }

    return found;
}

function faced(node) {
    const rule = node.parent;

    return rule !== undefined && rule.type === 'atrule' && rule.name.toLowerCase() === 'font-face';
}

const BYTE_ORDER_MARK = '\uFEFF';

function collect(whole, path) {
    const definitions = [];
    const uses = [];

    const marked = whole.startsWith(BYTE_ORDER_MARK);
    const source = marked ? whole.slice(BYTE_ORDER_MARK.length) : whole;
    const shift = marked ? Buffer.byteLength(BYTE_ORDER_MARK, 'utf8') : 0;
    const root = postcss.parse(source, { from: path });

    root.walkDecls((decl) => {
        const start = decl.source?.start?.offset;

        if (start === undefined) {
            return;
        }

        const property = decl.prop;

        if (property.startsWith('--')) {
            definitions.push(['custom-property', property, shift + byteOffset(source, start)]);

            return;
        }

        const between = decl.raws.between ?? ':';
        const base = start + property.length + between.length;
        const lowered = property.toLowerCase();

        if (lowered === 'font-family') {
            const kind = faced(decl) ? definitions : uses;

            for (const held of valuesOf(decl.value, base)) {
                kind.push(['font-family', held.name, shift + byteOffset(source, held.offset)]);
            }

            return;
        }

        if (lowered === 'animation-name') {
            for (const held of valuesOf(decl.value, base)) {
                uses.push(['keyframes', held.name, shift + byteOffset(source, held.offset)]);
            }
        }
    });

    root.walkAtRules((rule) => {
        if (!rule.name.toLowerCase().endsWith('keyframes')) {
            return;
        }

        const start = rule.source?.start?.offset;

        if (start === undefined || rule.params.length === 0) {
            return;
        }

        const after = rule.raws.afterName ?? ' ';
        const offset = start + 1 + rule.name.length + after.length;

        definitions.push(['keyframes', rule.params, shift + byteOffset(source, offset)]);
    });

    root.walkDecls((decl) => {
        const start = decl.source?.start?.offset;

        if (start === undefined) {
            return;
        }

        const between = decl.raws.between ?? ':';
        const base = start + decl.prop.length + between.length;

        for (const match of decl.value.matchAll(/var\(\s*(--[^\s,)]+)/g)) {
            const offset = base + match.index + match[0].length - match[1].length;

            uses.push(['custom-property', match[1], shift + byteOffset(source, offset)]);
        }
    });

    definitions.sort();
    uses.sort();

    return { definitions, uses };
}

function sources(root, out) {
    for (const entry of readdirSync(root)) {
        const path = join(root, entry);
        let held;

        try {
            held = statSync(path);
        } catch {
            continue;
        }

        if (held.isDirectory()) {
            sources(path, out);

            continue;
        }

        if (path.endsWith('.css')) {
            out.push(path);
        }
    }
}

function main() {
    const [sourceRoot, destination] = process.argv.slice(2);

    if (sourceRoot === undefined || destination === undefined) {
        console.error('usage: dump.mjs <source-root> <destination>');

        return 2;
    }

    const found = [];

    sources(sourceRoot, found);
    found.sort();

    let written = 0;
    let broken = 0;

    for (const path of found) {
        const name = relative(sourceRoot, path).split(sep).join('/');
        let held;

        try {
            held = collect(readFileSync(path, 'utf8'), path);
        } catch {
            held = { broken: true, definitions: [], uses: [] };
            broken += 1;
        }

        const target = join(destination, `${name}.json`);

        mkdirSync(dirname(target), { recursive: true });
        writeFileSync(
            target,
            `${JSON.stringify({ postcss: VERSION, ...held })}\n`,
        );

        written += 1;
    }

    console.log(`wrote ${written} files for postcss ${VERSION}, ${broken} broken`);

    return 0;
}

process.exit(main());
