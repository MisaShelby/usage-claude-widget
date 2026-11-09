// Cas de référence partagés : calculés ici avec budget.js / strings.js, puis
// vérifiés à l'identique par la version Windows (windows/tests/Run-Tests.ps1).
//   TZ=Europe/Paris node tests/make-vectors.js > tests/vectors.json
// tests/vectors.test.js échoue si le fichier n'est plus à jour.

import * as B from '../claude-budget@misashelby/budget.js';
import { pickLang } from '../claude-budget@misashelby/strings.js';

const at = s => new Date(s).getTime();
const RESET = at('2026-11-10T15:00:00+01:00'); // mardi 15:00, Paris
const RESET_DST = at('2026-10-27T15:00:00+01:00'); // semaine du passage à l'heure d'hiver (25 oct.)
const NEXT = at('2026-11-17T15:00:00+01:00');

const USAGE_TEXT = `You are currently using your subscription to power your Claude Code usage

Current session: 2% used · resets Nov 9, 1:10pm (Europe/Paris)
Current week (all models): 49% used · resets Nov 10, 3pm (Europe/Paris)
`;

const days = (now, reset) => B.daysUntilReset(now, reset);
const history = {
    '2026-11-04': { budget: 15, start: 0, used: 9 },
    '2026-11-05': { budget: 15.6, start: 9, used: 17.5 },
    '2026-11-06': { budget: 17.9, start: 26.5, used: 12 },
};
const state = { dayKey: '2026-11-09', resetAt: RESET, dayStartUtil: 49, notified: [25], history };

const cases = [];
const add = (fn, ...args) => cases.push({ fn, args, expected: B[fn] ? B[fn](...args) : OTHER[fn](...args) });
const OTHER = { pickLang };

for (const [now, reset] of [
    [at('2026-11-06T10:50:00+01:00'), RESET],
    [at('2026-11-10T15:30:00+01:00'), NEXT],
    [at('2026-11-10T09:00:00+01:00'), RESET],
    [at('2026-10-21T08:00:00+02:00'), RESET_DST],
    [at('2026-10-25T23:30:00+01:00'), RESET_DST],
])
    add('daysUntilReset', now, reset);

add('allocate', 60, days(at('2026-11-06T10:50:00+01:00'), RESET));
add('allocate', 6, days(at('2026-11-06T10:50:00+01:00'), RESET));
add('allocate', 40, days(at('2026-11-07T09:00:00+01:00'), RESET));
add('allocate', 30, days(at('2026-11-08T09:00:00+01:00'), at('2026-11-09T15:00:00+01:00')));
add('allocate', -5, days(at('2026-11-06T10:50:00+01:00'), RESET));

for (const [utilization, dayStartUtil, now, reset] of [
    [49, 49, at('2026-11-09T11:50:00+01:00'), RESET],
    [60, 49, at('2026-11-09T18:00:00+01:00'), RESET],
    [95, 49, at('2026-11-09T22:00:00+01:00'), RESET],
    [43, 40, at('2026-11-06T10:50:00+01:00'), RESET],
    [20, 10, at('2026-11-07T12:00:00+01:00'), RESET],
    [100, 98, at('2026-11-10T14:00:00+01:00'), RESET],
    [70, 70, at('2026-11-10T14:59:00+01:00'), RESET],
    [30, 22, at('2026-10-24T12:00:00+02:00'), RESET_DST],
])
    add('computeStatus', { utilization, dayStartUtil, resetAt: reset, now });

add('checkThresholds', 30, []);
add('checkThresholds', 30, [25]);
add('checkThresholds', 80, [25]);
add('checkThresholds', 100, [25, 50, 75]);
add('checkThresholds', 120, []);
add('checkThresholds', Infinity, [25, 50, 75, 100]);

add('rollDayState', null, { utilization: 42, resetAt: RESET, now: at('2026-11-06T10:50:00+01:00') });
add('rollDayState', state, { utilization: 52, resetAt: RESET, now: at('2026-11-09T20:00:00+01:00') });
add('rollDayState', state, { utilization: 55, resetAt: RESET, now: at('2026-11-10T08:00:00+01:00') });
add('rollDayState', state, { utilization: 1, resetAt: NEXT, now: at('2026-11-10T15:05:00+01:00') });
add('rollDayState', { ...state, resetAt: RESET + 60000 }, { utilization: 50, resetAt: RESET, now: at('2026-11-09T12:00:00+01:00') });

add('recordDay', state, { todayBudget: 31.4, usedToday: 2 });
add('recordDay', { dayKey: '2026-11-06', resetAt: RESET, dayStartUtil: 43, notified: [] }, { todayBudget: 17.9, usedToday: 5 });

{
    const now = at('2026-11-09T11:50:00+01:00');
    const status = B.computeStatus({ utilization: 52, dayStartUtil: 49, resetAt: RESET, now });
    add('weekChart', { state, status, resetAt: RESET });
    const sparse = { ...state, history: { '2026-11-05': history['2026-11-05'] } };
    add('weekChart', { state: sparse, status, resetAt: RESET });
}

for (const v of [0, -3, 3, 9.5, 17.9, 31.4, 47, 100])
    add('chartScale', v);
for (const v of [0, 49.9, 50, 74.9, 75, 120, Infinity])
    add('barLevel', v);
for (const v of [0, 42, 100, 140, Infinity])
    add('barFraction', v);
add('weekElapsed', at('2026-11-09T11:50:00+01:00'), RESET);
add('weekElapsed', at('2026-11-01T00:00:00+01:00'), RESET);
add('planFractions', 20, [{ budget: 10 }, { budget: 25 }, { budget: 5 }]);
add('planFractions', 0, []);
add('normalizeReset', '2026-11-10T13:59:59.690856+00:00');
add('normalizeReset', '2026-11-10T14:00:29+00:00');
add('localKey', at('2026-11-09T23:59:00+01:00'));
add('localKey', at('2026-11-10T00:00:00+01:00'));

add('parseUsageText', USAGE_TEXT, at('2026-11-09T11:50:00+01:00'));
add('parseUsageText', 'Current week (all models): 48.5% used · resets Nov 10, 2:59pm (Europe/Paris)', at('2026-11-09T11:50:00+01:00'));
add('parseUsageText', 'Current week (all models): 10% used · resets Nov 10, 12:00 PM', at('2026-11-09T11:50:00+01:00'));
add('parseUsageText', 'Current week (all models): 10% used · resets Nov 10, 12am', at('2026-11-09T11:50:00+01:00'));
add('parseUsageText', 'Current week (all models): 30% used · resets Jan 2, 3pm (Europe/Paris)', at('2026-12-29T10:00:00+01:00'));
add('parseUsageText', 'Current week (all models): 30% used · resets soon', at('2026-11-09T11:50:00+01:00'));
add('parseUsageText', 'Error: not logged in', at('2026-11-09T11:50:00+01:00'));
add('parseUsageText', 'Current week (all models): 140% used', at('2026-11-09T11:50:00+01:00'));
add('parseUsageText', 'Current week (all models): 12% used · resets Oct 27, 3pm', at('2026-10-24T12:00:00+02:00'));

add('pickReset', RESET, RESET + 5 * 60000, at('2026-11-09T11:50:00+01:00'));
add('pickReset', RESET, NEXT, at('2026-11-10T15:05:00+01:00'));
add('pickReset', RESET, null, at('2026-11-09T11:50:00+01:00'));
add('pickReset', RESET, null, at('2026-11-10T15:05:00+01:00'));
add('pickReset', null, null, at('2026-11-09T11:50:00+01:00'));

for (const lang of ['fr', 'en']) {
    for (const v of [0, 5, 18.2857, 0.04, 99.95, -0.04])
        add('fmtPct', v, lang);
    add('pctText', 18.2857, lang);
    for (const v of [0, 62.4, 62.5, 100, Infinity])
        add('progressText', v, lang);
    for (const key of ['2026-11-07', '2026-11-08', '2026-11-10'])
        add('dayLabel', key, lang);
}
for (const names of [['fr_FR.UTF-8', 'fr'], ['en_US'], ['de_DE', 'fr'], ['fy_NL'], []])
    add('pickLang', names);

// JSON n'a pas d'Infinity : on l'écrit "Infinity".
const json = JSON.stringify({ timezone: 'Europe/Paris', cases },
    (k, v) => (typeof v === 'number' && !Number.isFinite(v) ? String(v) : v), 1);
process.stdout.write(`${json}\n`);
