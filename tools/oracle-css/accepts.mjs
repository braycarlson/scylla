// The runner consults postcss when tree-sitter-css and scylla disagree over whether a
// file is valid. The grammar cannot read every construct CSS has, and a verdict it gives
// is not evidence about scylla until a real parser gives the same one.
//
//   node accepts.mjs <path>...   prints `accepts <path>` or `rejects <path>` per path
//   node accepts.mjs --version   prints the postcss version, which the runner pins

import postcss from 'postcss';
import { createRequire } from 'node:module';
import { readFileSync } from 'node:fs';

const paths = process.argv.slice(2);

if (paths[0] === '--version') {
    const require = createRequire(import.meta.url);

    console.log(require('postcss/package.json').version);
} else {
    for (const path of paths) {
        let verdict;

        try {
            postcss.parse(readFileSync(path, 'utf8'), { from: path });
            verdict = 'accepts';
        } catch {
            verdict = 'rejects';
        }

        console.log(`${verdict} ${path}`);
    }
}
