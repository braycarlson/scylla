// Records what parse5 reads out of every `.html` under a root, one JSON per file: the
// elements it finds, the attributes each one carries, the `id` each attribute declares and
// the reference each one makes. parse5 is the HTML5 parser jsdom and Angular are built on,
// and it is the only independent implementation the markup model has.
//
// Rows are the shape `tools/oracle-css` writes -- `[kind, name, byte offset]` -- so the
// suites read the two roots the same way.

import { parse, parseFragment } from 'parse5';
import { mkdirSync, readdirSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { dirname, join, relative, sep } from 'node:path';

const VERSION = readFileSync(new URL('./PIN', import.meta.url), 'utf8').trim();

// An attribute whose value names an element by its `id`. `headers` and the ARIA relations
// name a whole list of them, separated by whitespace; the rest name exactly one.
const LISTED = new Set([
    'aria-activedescendant',
    'aria-controls',
    'aria-describedby',
    'aria-details',
    'aria-errormessage',
    'aria-flowto',
    'aria-labelledby',
    'aria-owns',
    'headers',
]);

const SINGULAR = new Set(['form', 'for', 'list']);

// A fragment reference: the value names an `id` only when it opens with `#`.
const FRAGMENT = new Set(['href', 'usemap', 'xlink:href']);

// parse5 reports an offset in UTF-16 code units. Every span scylla holds is a byte offset,
// so the prefix is measured rather than counted.
function byteOffset(source, offset) {
    return Buffer.byteLength(source.slice(0, offset), 'utf8');
}

// A value carrying a template hole names nothing static: `id="{{ slug }}"` is a name the
// template decides. scylla records no name for one, so neither does the oracle.
function templated(text) {
    return text.includes('{{') || text.includes('{%') || text.includes('{#');
}

const HOLES = [
    ['{{', '}}'],
    ['{%', '%}'],
    ['{#', '#}'],
];

// parse5 knows nothing of Django's templates, so `<li{% if wide %} class="w"{% endif %}>`
// reads to it as an element named `li{%` carrying attributes named `if` and `%}`, and the
// `<em>` inside `{% translate 'Server Error <em>(500)</em>' %}` reads as an element the
// document does not hold. Each construct is therefore blanked to spaces of its own length
// before parsing: every offset stays where it was, and what is left is the HTML the
// template writes around them, which is exactly what scylla reads.
function blanked(source) {
    let held = source;

    for (let offset = 0; offset < held.length; ) {
        const opener = HOLES.find(([open]) => held.startsWith(open, offset));

        if (opener === undefined) {
            offset += 1;

            continue;
        }

        const close = held.indexOf(opener[1], offset + opener[0].length);

        if (close < 0) {
            offset += opener[0].length;

            continue;
        }

        const stop = close + opener[1].length;
        const inner = held
            .slice(offset, stop)
            .replace(/[^\n]/gu, ' ');

        held = held.slice(0, offset) + inner + held.slice(stop);
        offset = stop;
    }

    return held;
}

function nameAt(source, offset) {
    let end = offset;

    while (end < source.length && !' \t\n\r\f/>='.includes(source[end])) {
        end += 1;
    }

    return source.slice(offset, end);
}

// The attribute's own span runs from its name to the end of its value. The value starts
// after the first `=`, past a quote where one is written.
function valueAt(source, location) {
    const whole = source.slice(location.startOffset, location.endOffset);
    const equals = whole.indexOf('=');

    if (equals < 0) {
        return null;
    }

    let offset = equals + 1;

    while (offset < whole.length && ' \t\n\r\f'.includes(whole[offset])) {
        offset += 1;
    }

    const quote = whole[offset];

    if (quote === '"' || quote === "'") {
        const end = whole.indexOf(quote, offset + 1);

        if (end < 0) {
            return null;
        }

        return { offset: location.startOffset + offset + 1, text: whole.slice(offset + 1, end) };
    }

    return { offset: location.startOffset + offset, text: whole.slice(offset) };
}

// A whitespace-separated list of names, each carrying the offset it was written at.
function namesOf(text, base) {
    const found = [];
    let offset = 0;

    while (offset < text.length) {
        if (' \t\n\r\f'.includes(text[offset])) {
            offset += 1;

            continue;
        }

        let end = offset;

        while (end < text.length && !' \t\n\r\f'.includes(text[end])) {
            end += 1;
        }

        found.push({ name: text.slice(offset, end), offset: base + offset });
        offset = end;
    }

    return found;
}

function collect(source) {
    const attributes = [];
    const definitions = [];
    const elements = [];
    const uses = [];

    // Names are read out of the BLANKED text, where `<form{% if x %}>` has become `<form`
    // followed by spaces, and offsets are measured against the original bytes.
    const held = blanked(source);

    // A template that opens with `<tr>` or `<td>` is a fragment of a table, and the document
    // parser drops an element written where a document may not hold it. The fragment parser
    // keeps it, so a source that names no document is read as one.
    const whole = /<(?:!doctype|html\b)/iu.test(held);
    const document = whole
        ? parse(held, { sourceCodeLocationInfo: true })
        : parseFragment(held, { sourceCodeLocationInfo: true });

    const pending = [document];

    while (pending.length > 0) {
        const node = pending.pop();

        for (const child of node.childNodes ?? []) {
            pending.push(child);
        }

        // A `<template>` holds its children in a document fragment of its own rather than in
        // `childNodes`, and `trace_viewer_full.html` writes three thousand elements inside
        // one. Nothing below it would be read without this.
        if (node.content !== undefined) {
            pending.push(node.content);
        }

        const location = node.sourceCodeLocation;

        // parse5 inserts `html`, `head` and `body` where a document leaves them out, and an
        // inserted element carries no location. Nothing in the source stands for it.
        if (!location || !location.startTag) {
            continue;
        }

        const offset = location.startTag.startOffset + 1;

        elements.push(['element', nameAt(held, offset), byteOffset(source, offset)]);

        for (const [name, found] of Object.entries(location.attrs ?? {})) {
            attributes.push([
                'attribute',
                nameAt(held, found.startOffset),
                byteOffset(source, found.startOffset),
            ]);

            const value = valueAt(source, found);

            if (value === null || templated(value.text)) {
                continue;
            }

            if (name === 'id') {
                if (value.text.length > 0) {
                    definitions.push(['id', value.text, byteOffset(source, value.offset)]);
                }

                continue;
            }

            if (LISTED.has(name)) {
                for (const found of namesOf(value.text, value.offset)) {
                    uses.push(['id', found.name, byteOffset(source, found.offset)]);
                }

                continue;
            }

            if (SINGULAR.has(name) && value.text.length > 0 && !/\s/.test(value.text)) {
                uses.push(['id', value.text, byteOffset(source, value.offset)]);

                continue;
            }

            if (FRAGMENT.has(name) && value.text.startsWith('#') && value.text.length > 1) {
                uses.push(['id', value.text.slice(1), byteOffset(source, value.offset + 1)]);
            }
        }
    }

    attributes.sort();
    definitions.sort();
    elements.sort();
    uses.sort();

    return { attributes, definitions, elements, uses };
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

        if (path.endsWith('.html')) {
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
            held = collect(readFileSync(path, 'utf8'));
        } catch {
            held = { attributes: [], broken: true, definitions: [], elements: [], uses: [] };
            broken += 1;
        }

        const target = join(destination, `${name}.json`);

        mkdirSync(dirname(target), { recursive: true });
        writeFileSync(target, `${JSON.stringify({ parse5: VERSION, ...held })}\n`);

        written += 1;
    }

    console.log(`wrote ${written} files for parse5 ${VERSION}, ${broken} broken`);

    return 0;
}

process.exit(main());
