import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';

// La version Windows est vérifiée sur tests/vectors.json : il doit suivre budget.js.
test('tests/vectors.json est à jour (TZ=Europe/Paris node tests/make-vectors.js)', () => {
    const fresh = execFileSync(process.execPath, [new URL('./make-vectors.js', import.meta.url).pathname],
        { env: { ...process.env, TZ: 'Europe/Paris' }, encoding: 'utf8' });
    const saved = readFileSync(new URL('./vectors.json', import.meta.url), 'utf8');
    assert.equal(saved, fresh);
});
