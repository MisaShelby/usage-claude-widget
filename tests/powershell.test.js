import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

// Garde-fous pour les scripts Windows, vérifiables sans Windows.
const root = new URL('../windows/', import.meta.url).pathname;
const scripts = dir => readdirSync(dir, { withFileTypes: true }).flatMap(e =>
    e.isDirectory() ? scripts(join(dir, e.name)) : e.name.endsWith('.ps1') ? [join(dir, e.name)] : []);

test('les scripts PowerShell commencent par un BOM UTF-8 (sinon 5.1 les lit en ANSI)', () => {
    for (const file of scripts(root))
        assert.deepEqual([...readFileSync(file).subarray(0, 3)], [0xef, 0xbb, 0xbf], file);
});

test('aucune apostrophe typographique dans une chaîne entre apostrophes (PowerShell y voit une fin de chaîne)', () => {
    for (const file of scripts(root)) {
        readFileSync(file, 'utf8').split('\n').forEach((line, i) => {
            const code = line.replace(/^\s*#.*$/, '');
            assert.ok(!/'[^'"\n]*[‘’‚‛]/.test(code), `${file}:${i + 1}: ${line.trim()}`);
        });
    }
});
