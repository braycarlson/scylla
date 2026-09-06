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
