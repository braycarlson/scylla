import postcss from 'postcss';
import { readFileSync, readdirSync, statSync } from 'node:fs';
import { join } from 'node:path';

function walk(root, out) {
    for (const entry of readdirSync(root)) {
        const path = join(root, entry);
        let held;
        try { held = statSync(path); } catch { continue; }
        if (held.isDirectory()) { walk(path, out); continue; }
        if (path.endsWith('.css')) out.push(path);
    }
}

const files = [];
walk(process.argv[2], files);

let parsed = 0, failed = 0, definitions = 0, uses = 0;

for (const path of files) {
    let root;
    try {
        root = postcss.parse(readFileSync(path, 'utf8'), { from: path });
    } catch { failed += 1; continue; }
    parsed += 1;
    root.walkDecls((decl) => {
        if (decl.prop.startsWith('--')) definitions += 1;
        for (const _ of decl.value.matchAll(/var\(\s*(--[\w-]+)/g)) uses += 1;
    });
    root.walkAtRules(/keyframes$/, () => { definitions += 1; });
}

console.log(`files ${files.length} parsed ${parsed} failed ${failed} definitions ${definitions} uses ${uses}`);
