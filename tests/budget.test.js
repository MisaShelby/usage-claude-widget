import { test } from 'node:test';
import assert from 'node:assert/strict';

import {
    WEEKEND_SHARE,
    normalizeReset,
    daysUntilReset,
    allocate,
    computeStatus,
    checkThresholds,
    rollDayState,
    fmtPct,
    dayLabel,
    recordDay,
    weekChart,
    chartScale,
    progressText,
    barFraction,
    barLevel,
    weekElapsed,
    planFractions,
    parseUsageText,
    pickReset,
} from '../claude-budget@misashelby/budget.js';

// Les tests tournent en Europe/Paris (voir package.json).
const paris = s => new Date(s).getTime();
const near = (actual, expected, msg) =>
    assert.ok(Math.abs(actual - expected) < 0.01, `${msg ?? ''} attendu ${expected}, obtenu ${actual}`);

const RESET = paris('2026-11-10T14:00:00Z'); // mardi 10 nov. 15:00 heure de Paris

test('la réserve week-end vaut 10 % de la semaine', () => {
    assert.equal(WEEKEND_SHARE, 10);
});

test('normalizeReset arrondit resets_at de l’API à la minute', () => {
    assert.equal(normalizeReset('2026-11-10T13:59:59.690856+00:00'), RESET);
});

test('daysUntilReset découpe vendredi → mardi avec le mardi partiel', () => {
    const days = daysUntilReset(paris('2026-11-06T10:50:00+01:00'), RESET);
    assert.deepEqual(days.map(d => d.key), ['2026-11-06', '2026-11-07', '2026-11-08', '2026-11-09', '2026-11-10']);
    assert.deepEqual(days.map(d => d.weekend), [false, true, true, false, false]);
    assert.deepEqual(days.slice(0, 4).map(d => d.weight), [1, 1, 1, 1]);
    near(days[4].weight, 15 / 24, 'mardi jusqu’à 15:00');
});

test('daysUntilReset le jour du reset ne compte que les heures après le reset', () => {
    const days = daysUntilReset(paris('2026-11-10T16:00:00+01:00'), paris('2026-11-17T14:00:00Z'));
    assert.equal(days.length, 8);
    assert.equal(days[0].key, '2026-11-10');
    near(days[0].weight, 9 / 24, 'mardi après 15:00');
    near(days[7].weight, 15 / 24, 'mardi suivant jusqu’à 15:00');
    near(days.reduce((s, d) => s + d.weight, 0), 7, 'une semaine complète');
});

test('allocate garde 5 % par jour de week-end et répartit le reste sur les jours de semaine', () => {
    const days = daysUntilReset(paris('2026-11-06T10:50:00+01:00'), RESET);
    const budgets = allocate(58, days);
    near(budgets[1], 5, 'samedi');
    near(budgets[2], 5, 'dimanche');
    near(budgets[0], 48 / 2.625, 'vendredi');
    near(budgets[3], 48 / 2.625, 'lundi');
    near(budgets[4], 48 * 0.625 / 2.625, 'mardi partiel');
    near(budgets.reduce((a, b) => a + b, 0), 58, 'tout le restant est réparti');
});

test('allocate donne tout au week-end si le restant est sous la réserve', () => {
    const days = daysUntilReset(paris('2026-11-06T10:50:00+01:00'), RESET);
    const budgets = allocate(6, days);
    assert.deepEqual(budgets.map(b => Math.round(b * 100) / 100), [0, 3, 3, 0, 0]);
});

test('allocate le samedi : 5 % samedi et dimanche, le reste pour lundi et mardi', () => {
    const days = daysUntilReset(paris('2026-11-07T09:00:00+01:00'), RESET);
    const budgets = allocate(40, days);
    near(budgets[0], 5, 'samedi');
    near(budgets[1], 5, 'dimanche');
    near(budgets[2], 30 / 1.625, 'lundi');
    near(budgets[3], 30 * 0.625 / 1.625, 'mardi');
});

test('allocate sans jour de semaine restant donne tout aux jours restants', () => {
    const days = [{ weight: 1, weekend: true }, { weight: 1, weekend: true }];
    assert.deepEqual(allocate(30, days), [15, 15]);
});

test('computeStatus calcule le budget du jour depuis l’usage du début de journée', () => {
    const s = computeStatus({
        utilization: 45, dayStartUtil: 42, resetAt: RESET, now: paris('2026-11-06T15:00:00+01:00'),
    });
    near(s.todayBudget, 48 / 2.625, 'budget du jour');
    near(s.usedToday, 3, 'utilisé aujourd’hui');
    near(s.progress, 3 / (48 / 2.625) * 100, 'progression');
});

test('computeStatus sous le budget : les jours suivants gardent leur part', () => {
    const s = computeStatus({
        utilization: 45, dayStartUtil: 42, resetAt: RESET, now: paris('2026-11-06T15:00:00+01:00'),
    });
    assert.deepEqual(s.upcoming.map(d => d.key), ['2026-11-07', '2026-11-08', '2026-11-09', '2026-11-10']);
    near(s.upcoming[0].budget, 5, 'samedi');
    near(s.upcoming[2].budget, 48 / 2.625, 'lundi inchangé');
});

test('computeStatus en dépassement : les jours suivants sont recalculés à la baisse', () => {
    const s = computeStatus({
        utilization: 65, dayStartUtil: 42, resetAt: RESET, now: paris('2026-11-06T18:00:00+01:00'),
    });
    assert.ok(s.progress > 100);
    near(s.upcoming[0].budget, 5, 'samedi garde sa réserve');
    near(s.upcoming[1].budget, 5, 'dimanche garde sa réserve');
    near(s.upcoming[2].budget, 25 / 1.625, 'lundi réduit');
    near(s.upcoming[3].budget, 25 * 0.625 / 1.625, 'mardi réduit');
    near(s.upcoming.reduce((a, d) => a + d.budget, 0), 35, 'le restant réel est réparti');
});

test('computeStatus avec un budget du jour nul compte comme limite atteinte', () => {
    const s = computeStatus({
        utilization: 100, dayStartUtil: 100, resetAt: RESET, now: paris('2026-11-09T10:00:00+01:00'),
    });
    assert.equal(s.todayBudget, 0);
    assert.equal(s.progress, 100);
});

test('checkThresholds notifie le premier palier franchi', () => {
    assert.deepEqual(checkThresholds(30, []), { level: 25, notified: [25] });
});

test('checkThresholds ne renotifie pas un palier déjà annoncé', () => {
    assert.deepEqual(checkThresholds(30, [25]), { level: null, notified: [25] });
});

test('checkThresholds ne garde que le palier le plus haut franchi d’un coup', () => {
    assert.deepEqual(checkThresholds(80, [25]), { level: 75, notified: [25, 50, 75] });
});

test('checkThresholds annonce 100 % pile comme limite atteinte', () => {
    assert.deepEqual(checkThresholds(100, [25, 50, 75]), { level: 100, notified: [25, 50, 75, 100] });
});

test('checkThresholds annonce le dépassement au-delà de 100 %', () => {
    assert.deepEqual(checkThresholds(112, [25, 50, 75]), { level: 'over', notified: [25, 50, 75, 100, 'over'] });
    assert.deepEqual(checkThresholds(112, [25, 50, 75, 100]), { level: 'over', notified: [25, 50, 75, 100, 'over'] });
    assert.deepEqual(checkThresholds(150, [25, 50, 75, 100, 'over']), { level: null, notified: [25, 50, 75, 100, 'over'] });
});

test('rollDayState garde l’état dans la même journée', () => {
    const state = { dayKey: '2026-11-06', resetAt: RESET, dayStartUtil: 42, notified: [25] };
    const next = rollDayState(state, { utilization: 50, resetAt: RESET, now: paris('2026-11-06T20:00:00+01:00') });
    assert.deepEqual(next, state);
});

test('rollDayState repart de zéro un nouveau jour', () => {
    const state = { dayKey: '2026-11-06', resetAt: RESET, dayStartUtil: 42, notified: [25] };
    const next = rollDayState(state, { utilization: 50, resetAt: RESET, now: paris('2026-11-07T08:00:00+01:00') });
    assert.deepEqual(next, { dayKey: '2026-11-07', resetAt: RESET, dayStartUtil: 50, notified: [], history: {} });
});

test('rollDayState repart de zéro après le reset hebdomadaire du mardi', () => {
    const state = { dayKey: '2026-11-10', resetAt: RESET, dayStartUtil: 95, notified: [25, 50] };
    const newReset = paris('2026-11-17T14:00:00Z');
    const next = rollDayState(state, { utilization: 0, resetAt: newReset, now: paris('2026-11-10T15:05:00+01:00') });
    assert.deepEqual(next, { dayKey: '2026-11-10', resetAt: newReset, dayStartUtil: 0, notified: [], history: {} });
});

test('rollDayState initialise un état vide', () => {
    const next = rollDayState(null, { utilization: 42, resetAt: RESET, now: paris('2026-11-06T10:50:00+01:00') });
    assert.deepEqual(next, { dayKey: '2026-11-06', resetAt: RESET, dayStartUtil: 42, notified: [], history: {} });
});

test('fmtPct formate à la française avec une décimale au plus', () => {
    assert.equal(fmtPct(18.2857), '18,3');
    assert.equal(fmtPct(5), '5');
    assert.equal(fmtPct(0.04), '0');
});

test('dayLabel donne le jour court en français', () => {
    assert.equal(dayLabel('2026-11-07'), 'sam. 7');
    assert.equal(dayLabel('2026-11-10'), 'mar. 10');
});

// --- Historique de la semaine et graphique ---

const HIST = {
    '2026-11-04': { budget: 14, start: 3, used: 12 },
    '2026-11-05': { budget: 13.5, start: 15.5, used: 9 },
};

test('rollDayState garde l’historique de la semaine au changement de jour', () => {
    const state = { dayKey: '2026-11-06', resetAt: RESET, dayStartUtil: 42, notified: [25], history: HIST };
    const next = rollDayState(state, { utilization: 50, resetAt: RESET, now: paris('2026-11-07T08:00:00+01:00') });
    assert.deepEqual(next.history, HIST);
});

test('rollDayState vide l’historique à la nouvelle semaine', () => {
    const state = { dayKey: '2026-11-10', resetAt: RESET, dayStartUtil: 95, notified: [], history: HIST };
    const next = rollDayState(state, { utilization: 0, resetAt: paris('2026-11-17T14:00:00Z'), now: paris('2026-11-10T15:05:00+01:00') });
    assert.deepEqual(next.history, {});
});

test('recordDay enregistre budget, départ et usage du jour sans toucher aux autres jours', () => {
    const state = { dayKey: '2026-11-06', resetAt: RESET, dayStartUtil: 42, notified: [], history: HIST };
    const next = recordDay(state, { todayBudget: 18, usedToday: 6.5 });
    assert.deepEqual(next.history, { ...HIST, '2026-11-06': { budget: 18, start: 42, used: 6.5 } });
    assert.equal(state.history['2026-11-06'], undefined, 'état d’origine intact');
});

test('recordDay accepte un ancien état sans historique', () => {
    const state = { dayKey: '2026-11-06', resetAt: RESET, dayStartUtil: 43, notified: [] };
    const next = recordDay(state, { todayBudget: 17.9, usedToday: 1 });
    assert.deepEqual(next.history, { '2026-11-06': { budget: 17.9, start: 43, used: 1 } });
});

const statusAt = (utilization, dayStartUtil, iso) =>
    computeStatus({ utilization, dayStartUtil, resetAt: RESET, now: paris(iso) });

test('weekChart couvre la semaine de quota, du mardi 15:00 au mardi 15:00', () => {
    const state = { dayKey: '2026-11-06', resetAt: RESET, dayStartUtil: 27, notified: [], history: HIST };
    const { days } = weekChart({ state, status: statusAt(30, 27, '2026-11-06T12:00:00+01:00'), resetAt: RESET });
    assert.deepEqual(days.map(d => d.key), [
        '2026-11-03', '2026-11-04', '2026-11-05', '2026-11-06',
        '2026-11-07', '2026-11-08', '2026-11-09', '2026-11-10',
    ]);
    near(days[0].weight, 9 / 24, 'mardi dès 15:00');
    near(days[7].weight, 15 / 24, 'mardi jusqu’à 15:00');
    assert.deepEqual(days.map(d => d.weekend), [false, false, false, false, true, true, false, false]);
});

test('weekChart : jours passés enregistrés, aujourd’hui en cours, jours à venir prévus', () => {
    const history = { '2026-11-03': { budget: 6, start: 0, used: 3 }, ...HIST };
    const state = { dayKey: '2026-11-06', resetAt: RESET, dayStartUtil: 27, notified: [], history };
    const status = statusAt(30, 27, '2026-11-06T12:00:00+01:00');
    const { days, gaps } = weekChart({ state, status, resetAt: RESET });
    assert.deepEqual(gaps, []);
    assert.deepEqual(days.map(d => d.kind), ['past', 'past', 'past', 'today', 'future', 'future', 'future', 'future']);
    assert.deepEqual([days[1].budget, days[1].used], [14, 12]);
    assert.deepEqual([days[2].budget, days[2].used], [13.5, 9]);
    near(days[3].budget, status.todayBudget, 'budget du jour');
    near(days[3].used, 3, 'usage du jour');
    near(days[4].budget, 5, 'samedi prévu');
    assert.equal(days[4].used, null, 'pas d’usage pour un jour à venir');
    near(days[6].budget, status.upcoming[2].budget, 'lundi prévu');
});

test('weekChart regroupe les jours non suivis avec leur total', () => {
    // Suivi démarré vendredi : 43 % consommés de mardi 15:00 à vendredi matin.
    const state = { dayKey: '2026-11-06', resetAt: RESET, dayStartUtil: 43, notified: [], history: {} };
    const { days, gaps } = weekChart({ state, status: statusAt(49.4, 43, '2026-11-06T11:20:00+01:00'), resetAt: RESET });
    assert.deepEqual(days.slice(0, 3).map(d => [d.kind, d.budget, d.used]), [
        ['gap', null, null], ['gap', null, null], ['gap', null, null],
    ]);
    assert.deepEqual(gaps, [{ from: 0, to: 2, total: 43 }]);
});

test('weekChart : un jour éteint au milieu de la semaine compte ce qui a été consommé entre deux relevés', () => {
    // Mercredi suivi (3 → 15), jeudi éteint, vendredi démarre à 27.
    const state = { dayKey: '2026-11-06', resetAt: RESET, dayStartUtil: 27, notified: [],
        history: { '2026-11-03': { budget: 6, start: 0, used: 3 }, '2026-11-04': { budget: 14, start: 3, used: 12 } } };
    const { days, gaps } = weekChart({ state, status: statusAt(30, 27, '2026-11-06T12:00:00+01:00'), resetAt: RESET });
    assert.equal(days[2].kind, 'gap');
    assert.equal(gaps.length, 1);
    assert.deepEqual([gaps[0].from, gaps[0].to], [2, 2]);
    near(gaps[0].total, 12, 'jeudi : 27 − (3 + 12)');
});

test('weekChart sans jour manquant ne crée aucun bloc', () => {
    const state = { dayKey: '2026-11-03', resetAt: RESET, dayStartUtil: 0.2, notified: [], history: {} };
    const status = computeStatus({ utilization: 1, dayStartUtil: 0.2, resetAt: RESET, now: paris('2026-11-03T16:00:00+01:00') });
    const { days, gaps } = weekChart({ state, status, resetAt: RESET });
    assert.equal(days[0].kind, 'today');
    assert.deepEqual(gaps, []);
});

test('chartScale choisit une échelle ronde de 4 graduations au plus', () => {
    assert.deepEqual(chartScale(17.9), { max: 20, step: 5 });
    assert.deepEqual(chartScale(23), { max: 30, step: 10 });
    assert.deepEqual(chartScale(3.2), { max: 4, step: 1 });
    assert.deepEqual(chartScale(0), { max: 5, step: 5 });
});

test('progressText affiche le pourcentage du budget du jour', () => {
    assert.equal(progressText(29.6), '30 %');
    assert.equal(progressText(115.2), '115 %');
    assert.equal(progressText(Infinity), 'dépassé');
});

test('barFraction remplit la barre jusqu’au budget du jour puis la garde pleine', () => {
    assert.equal(barFraction(30), 0.3);
    assert.equal(barFraction(115), 1);
    assert.equal(barFraction(Infinity), 1);
    assert.equal(barFraction(-3), 0);
});

test('barLevel : vert sous 50 %, orange de 50 à 75 %, rouge à partir de 75 %', () => {
    assert.equal(barLevel(0), 'green');
    assert.equal(barLevel(-3), 'green');
    assert.equal(barLevel(30), 'green');
    assert.equal(barLevel(49.9), 'green');
    assert.equal(barLevel(50), 'orange');
    assert.equal(barLevel(74.9), 'orange');
    assert.equal(barLevel(75), 'red');
    assert.equal(barLevel(100), 'red');
    assert.equal(barLevel(115), 'red');
    assert.equal(barLevel(Infinity), 'red');
    assert.equal(barLevel(NaN), 'red');
});

test('weekElapsed donne la part écoulée de la semaine de quota', () => {
    near(weekElapsed(RESET - 7 * 24 * 3600 * 1000, RESET), 0);
    near(weekElapsed(paris('2026-11-06T15:00:00+01:00'), RESET), 3 / 7);
    near(weekElapsed(RESET, RESET), 1);
    near(weekElapsed(RESET + 3600 * 1000, RESET), 1);
});

test('planFractions mesure chaque jour à venir par rapport au plus gros budget, aujourd’hui compris', () => {
    const upcoming = [{ budget: 5 }, { budget: 5 }, { budget: 17.9 }, { budget: 11.2 }];
    const f = planFractions(17.9, upcoming);
    near(f[0], 5 / 17.9);
    near(f[2], 1);
    near(f[3], 11.2 / 17.9);
    // sous-consommation : un jour à venir peut dépasser le budget d'aujourd'hui
    near(planFractions(10, [{ budget: 20 }, { budget: 5 }])[1], 0.25);
    assert.deepEqual(planFractions(0, [{ budget: 0 }]), [0]);
    assert.deepEqual(planFractions(12, []), []);
});

// Sortie réelle de `claude -p /usage` (Claude Code 2.1.319), relevée le lun. 9 nov. 2026.
const USAGE_TEXT = `You are currently using your subscription to power your Claude Code usage

Current session: 2% used · resets Nov 9, 1:10pm (Europe/Paris)
Current week (all models): 49% used · resets Nov 10, 3pm (Europe/Paris)

What's contributing to your usage?
Last 7d · 168 requests · 6 sessions
  41%  Review the "superpowers" plugin
`;
const MONDAY = paris('2026-11-09T11:50:00+01:00');

test('parseUsageText lit la semaine, la session et la remise à zéro dans /usage', () => {
    assert.deepEqual(parseUsageText(USAGE_TEXT, MONDAY), { utilization: 49, session: 2, resetAt: RESET });
});

test('parseUsageText accepte les décimales, les minutes et arrondit l’heure à 5 min', () => {
    const text = 'Current week (all models): 48.5% used · resets Nov 10, 2:59pm (Europe/Paris)';
    assert.deepEqual(parseUsageText(text, MONDAY), { utilization: 48.5, session: null, resetAt: RESET });
});

test('parseUsageText accepte « 12:00 PM » et « 12am »', () => {
    const noon = parseUsageText('Current week (all models): 10% used · resets Nov 10, 12:00 PM', MONDAY);
    assert.equal(noon.resetAt, paris('2026-11-10T12:00:00+01:00'));
    const midnight = parseUsageText('Current week (all models): 10% used · resets Nov 10, 12am', MONDAY);
    assert.equal(midnight.resetAt, paris('2026-11-10T00:00:00+01:00'));
});

test('parseUsageText passe à l’année suivante fin décembre', () => {
    const text = 'Current week (all models): 30% used · resets Jan 2, 3pm (Europe/Paris)';
    const now = paris('2026-12-29T10:00:00+01:00');
    assert.equal(parseUsageText(text, now).resetAt, paris('2027-01-02T15:00:00+01:00'));
});

test('parseUsageText sans remise à zéro lisible garde le pourcentage', () => {
    const text = 'Current week (all models): 30% used · resets soon';
    assert.deepEqual(parseUsageText(text, MONDAY), { utilization: 30, session: null, resetAt: null });
});

test('parseUsageText sans ligne de semaine ne renvoie rien', () => {
    assert.equal(parseUsageText('Error: not logged in', MONDAY), null);
    assert.equal(parseUsageText('Current week (all models): 140% used', MONDAY), null);
});

test('pickReset garde la remise à zéro connue quand /usage en donne une voisine', () => {
    assert.equal(pickReset(RESET, RESET + 5 * 60000, MONDAY), RESET);
    assert.equal(pickReset(RESET, RESET - 80 * 60000, MONDAY), RESET);
});

test('pickReset prend la nouvelle remise à zéro quand elle est loin de la connue', () => {
    const next = paris('2026-11-17T14:00:00Z');
    assert.equal(pickReset(RESET, next, paris('2026-11-10T15:05:00+01:00')), next);
});

test('pickReset sans date lisible garde la connue si la semaine court encore', () => {
    assert.equal(pickReset(RESET, null, MONDAY), RESET);
    assert.equal(pickReset(RESET, null, paris('2026-11-10T15:05:00+01:00')), null);
    assert.equal(pickReset(undefined, null, MONDAY), null);
});

test('rollDayState garde la journée si la remise à zéro bouge de quelques minutes', () => {
    const state = { dayKey: '2026-11-09', resetAt: RESET + 60000, dayStartUtil: 49, notified: [25], history: { '2026-11-06': { budget: 18, start: 43, used: 5 } } };
    const next = rollDayState(state, { utilization: 52, resetAt: RESET, now: MONDAY });
    assert.deepEqual(next, { ...state, resetAt: RESET });
});

test('rollDayState garde l’historique si la remise à zéro bouge de quelques minutes un nouveau jour', () => {
    const state = { dayKey: '2026-11-08', resetAt: RESET + 60000, dayStartUtil: 45, notified: [], history: { '2026-11-06': { budget: 18, start: 43, used: 5 } } };
    const next = rollDayState(state, { utilization: 49, resetAt: RESET, now: MONDAY });
    assert.deepEqual(next, { dayKey: '2026-11-09', resetAt: RESET, dayStartUtil: 49, notified: [], history: state.history });
});
