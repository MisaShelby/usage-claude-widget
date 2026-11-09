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

// Alias de Windows PowerShell 5.1 : un alias passe avant une fonction du même nom.
const ALIASES = `ac asnp cat cd chdir clc clear clhy cli clp cls clv cnsn compare copy cp cpi cpp curl cvpa dbp
del diff dir dnsn ebp echo epal epcsv epsn erase etsn exsn fc fhx fl foreach ft fw gal gbp gc gcb gci gcm gcs gdr
ghy gi gin gjb gl gm gmo gp gps gpv group gsn gsnp gsv gtz gu gv gwmi h history icm iex ihy ii ipal ipcsv ipmo ipsn
irm ise iwmi iwr kill lp ls man md measure mi mount move mp mv nal ndr ni nmo npssc nsn nv ogv oh popd ps pushd pwd
r rbp rcjb rcsn rd rdr ren ri rjb rm rmdir rmo rni rnp rp rsn rsnp rujb rv rvpa rwmi sajb sal saps sasv sbp sc scb
select set shcm si sl sleep sls sort sp spjb spps spsv start stz sujb sv swmi tee trcm type wget where wjb write`
    .split(/\s+/);

test('aucune fonction PowerShell ne porte le nom d’un alias intégré', () => {
    for (const file of scripts(root)) {
        for (const [, name] of readFileSync(file, 'utf8').matchAll(/^\s*function\s+([\w-]+)/gm))
            assert.ok(!ALIASES.includes(name.toLowerCase()), `${file}: function ${name}`);
    }
});
