const fs = require('fs');
const ts = require('typescript');

const path = process.argv[2];

if (!path) {
    console.error('usage: oracle-lex-js <path>');
    process.exit(2);
}

const source = fs.readFileSync(path, 'utf8');
const kinds = {
    '.cjs': ts.ScriptKind.JS,
    '.cts': ts.ScriptKind.TS,
    '.js': ts.ScriptKind.JS,
    '.jsx': ts.ScriptKind.JSX,
    '.mjs': ts.ScriptKind.JS,
    '.mts': ts.ScriptKind.TS,
    '.ts': ts.ScriptKind.TS,
    '.tsx': ts.ScriptKind.TSX,
};
const suffix = path.slice(path.lastIndexOf('.'));
const script = kinds[suffix] === undefined ? ts.ScriptKind.JS : kinds[suffix];

const file = ts.createSourceFile(path, source, ts.ScriptTarget.Latest, true, script);

const lines = [];
const bytes = new Uint32Array(source.length + 1);

{
    let total = 0;

    for (let index = 0; index < source.length; index += 1) {
        bytes[index] = total;

        const code = source.codePointAt(index);

        if (code > 0xffff) {
            bytes[index + 1] = total;
            index += 1;
            total += 4;

            continue;
        }

        total += code < 0x80 ? 1 : code < 0x800 ? 2 : 3;
    }

    bytes[source.length] = total;
}

function byteOf(index) {
    return bytes[Math.min(index, source.length)];
}

function push(start, end, kind) {
    if (end <= start) {
        return;
    }

    const offset = byteOf(start);

    lines.push(`${offset}:${byteOf(end) - offset} ${kind}`);
}

const commented = new Set();

function trivia(fullStart) {
    const ranges = [
        ...(ts.getTrailingCommentRanges(source, fullStart) || []),
        ...(ts.getLeadingCommentRanges(source, fullStart) || []),
    ];

    for (const range of ranges) {
        if (commented.has(range.pos)) {
            continue;
        }

        commented.add(range.pos);
        push(range.pos, range.end, 'comment');
    }
}

const WHOLE = new Set([
    ts.SyntaxKind.TemplateExpression,
    ts.SyntaxKind.TemplateLiteralType,
    ts.SyntaxKind.NoSubstitutionTemplateLiteral,
]);

const NODE_COUNT_MAX = 1 << 22;

const DROPPED = new Set([
    ts.SyntaxKind.OpenBraceToken,
    ts.SyntaxKind.CloseBraceToken,
]);

const ELEMENTS = new Set([
    ts.SyntaxKind.JsxElement,
    ts.SyntaxKind.JsxFragment,
    ts.SyntaxKind.JsxSelfClosingElement,
]);

function documented(node) {
    return node.kind >= ts.SyntaxKind.FirstJSDocNode && node.kind <= ts.SyntaxKind.LastJSDocNode;
}

function walk(root) {
    const pending = [root];
    let steps = 0;

    while (pending.length > 0 && steps < NODE_COUNT_MAX) {
        steps += 1;

        const node = pending.pop();

        if (documented(node)) {
            continue;
        }

        if (WHOLE.has(node.kind)) {
            trivia(node.getFullStart());
            push(node.getStart(file), node.getEnd(), 'string');

            continue;
        }

        if (ELEMENTS.has(node.kind)) {
            push(node.getStart(file), node.getEnd(), 'jsx-element');
        }

        const children = node.getChildren(file).filter((child) => !documented(child));

        if (children.length > 0) {
            for (let index = children.length - 1; index >= 0; index -= 1) {
                pending.push(children[index]);
            }

            continue;
        }

        trivia(node.getFullStart());

        if (node.kind === ts.SyntaxKind.EndOfFileToken || DROPPED.has(node.kind)) {
            continue;
        }

        push(node.getStart(file), node.getEnd(), classOf(node.kind));
    }

    if (pending.length > 0) {
        throw new Error('the syntax tree is larger than the walk allows');
    }
}

if (source.startsWith('#!')) {
    const end = source.indexOf('\n');

    push(0, end === -1 ? source.length : end, 'comment');
}

walk(file);

lines.sort((left, right) => Number(left.split(':')[0]) - Number(right.split(':')[0]));

function classOf(kind) {
    if (kind === ts.SyntaxKind.Identifier || kind === ts.SyntaxKind.PrivateIdentifier) {
        return 'identifier';
    }

    if (kind === ts.SyntaxKind.NumericLiteral || kind === ts.SyntaxKind.BigIntLiteral) {
        return 'number';
    }

    if (kind === ts.SyntaxKind.StringLiteral || kind === ts.SyntaxKind.RegularExpressionLiteral) {
        return 'string';
    }

    if (kind >= ts.SyntaxKind.TemplateHead && kind <= ts.SyntaxKind.TemplateTail) {
        return 'string';
    }

    if (kind === ts.SyntaxKind.NoSubstitutionTemplateLiteral) {
        return 'string';
    }

    if (kind === ts.SyntaxKind.JsxText) {
        return 'jsx-text';
    }

    if (kind >= ts.SyntaxKind.FirstKeyword && kind <= ts.SyntaxKind.LastKeyword) {
        return 'keyword';
    }

    return 'punctuation';
}

process.stdout.write(lines.join('\n') + (lines.length ? '\n' : ''));
