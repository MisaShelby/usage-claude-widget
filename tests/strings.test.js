import { test } from 'node:test';
import assert from 'node:assert/strict';

import { pickLang, strings } from '../claude-budget@misashelby/strings.js';
import { fmtPct, pctText, progressText, dayLabel } from '../claude-budget@misashelby/budget.js';

test('pickLang suit la première langue reconnue du système', () => {
    assert.equal(pickLang(['fr_FR.UTF-8', 'fr_FR', 'fr', 'C']), 'fr');
    assert.equal(pickLang(['en_US.UTF-8', 'en_US', 'en', 'C']), 'en');
    assert.equal(pickLang(['de_DE.UTF-8', 'de', 'fr', 'C']), 'fr');
    assert.equal(pickLang(['de_DE.UTF-8', 'de', 'C']), 'en');
    assert.equal(pickLang(['C']), 'en');
    assert.equal(pickLang(['fy_NL', 'C']), 'en', 'fy (frison) n’est pas du français');
    assert.equal(pickLang(undefined), 'en');
});

test('les formats suivent la langue : virgule et espace en français', () => {
    assert.equal(fmtPct(18.2857, 'fr'), '18,3');
    assert.equal(fmtPct(18.2857, 'en'), '18.3');
    assert.equal(pctText(18.2857, 'fr'), '18,3 %');
    assert.equal(pctText(18.2857, 'en'), '18.3%');
    assert.equal(progressText(62.4, 'en'), '62%');
    assert.equal(progressText(Infinity, 'en'), 'over');
    assert.equal(progressText(Infinity, 'fr'), 'dépassé');
    assert.equal(dayLabel('2026-11-07', 'en'), 'Sat 7');
    assert.equal(dayLabel('2026-11-07', 'fr'), 'sam. 7');
});

test('strings donne les mêmes clés en français et en anglais', () => {
    const fr = strings('fr');
    const en = strings('en');
    assert.deepEqual(Object.keys(fr).sort(), Object.keys(en).sort());
    for (const key of Object.keys(fr))
        assert.equal(typeof fr[key], typeof en[key], key);
});

test('strings retombe sur l’anglais pour une langue inconnue', () => {
    assert.equal(strings('de').lang, 'en');
    assert.equal(strings('de').week, 'Week');
});

test('strings formate avec la langue choisie', () => {
    const fr = strings('fr');
    assert.equal(fr.weekValue(fr.pct(49), fr.pct(51)), '49 % utilisés · reste 51 %');
    assert.equal(fr.day('2026-11-10'), 'mar. 10');
    const en = strings('en');
    assert.equal(en.weekValue(en.pct(49), en.pct(51)), '49% used · 51% left');
    assert.equal(en.resetValue(en.day('2026-11-10'), '15:00', en.pct(84)), 'Tue 10 at 15:00  ·  84% elapsed');
    assert.equal(en.notifyLevelTitle(50), "Claude: 50% of today's budget");
});
