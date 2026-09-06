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
