// The runner consults typescript-estree when tree-sitter and scylla disagree over whether
// a file is valid. The grammar cannot read every construct TypeScript has -- `import('m').T`,
// `out T` variance, labelled tuple elements -- and a verdict it gives is not evidence about
// scylla until a real parser gives the same one.
//
//   node accepts.mjs <path>...   prints `accepts <path>` or `rejects <path>` per path
//   node accepts.mjs --version   prints the typescript-estree version, which the runner pins

import { parse } from '@typescript-eslint/typescript-estree';
import { createRequire } from 'node:module';
import { readFileSync } from 'node:fs';

const paths = process.argv.slice(2);

if (paths[0] === '--version') {
    const require = createRequire(import.meta.url);

    console.log(require('@typescript-eslint/typescript-estree/package.json').version);
} else {
    for (const path of paths) {
        let verdict;

        try {
            parse(readFileSync(path, 'utf8'), { jsx: path.endsWith('x') });
            verdict = 'accepts';
        } catch {
            verdict = 'rejects';
        }

        console.log(`${verdict} ${path}`);
    }
}
