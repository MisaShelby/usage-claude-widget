// Textes affichés par le widget, en français et en anglais.
// Module pur (aucun import GNOME) : testé avec node. La langue suit celle du
// système (pickLang) ; tout ce qui n'est pas du français s'affiche en anglais.

import { WEEKEND_SHARE, pctText, dayLabel } from './budget.js';

/**
 * Langue d'affichage d'après les langues préférées du système, dans l'ordre
 * (GLib.get_language_names() : ['fr_FR.UTF-8', 'fr_FR', 'fr', 'C']).
 */
export function pickLang(names) {
    for (const name of names ?? []) {
        if (/^fr([_.@-]|$)/i.test(name))
            return 'fr';
        if (/^en([_.@-]|$)/i.test(name))
            return 'en';
    }
    return 'en';
}

const FR = {
    title: 'Budget Claude',
    today: 'Aujourd’hui',
    todayOf: day => `Aujourd’hui (${day})`,
    week: 'Semaine',
    reset: 'Remise à zéro',
    session: 'Session (5 h)',
    upcomingHeader: `Prochains jours (réserve week-end ${WEEKEND_SHARE} %)`,
    lastDay: 'Dernier jour avant la remise à zéro',
    weekendSuffix: ' (week-end)',
    untilSuffix: time => ` (jusqu’à ${time})`,
    updated: 'Mis à jour',
    updatedViaCli: 'Mis à jour (via claude /usage)',
    viewWeek: 'Voir la semaine…',
    refreshNow: 'Actualiser maintenant',
    quit: 'Quitter',
    panelWeek: 'sem.',
    todayValue: (used, budget, progress) => `${used} / ${budget}  ·  ${progress}`,
    weekValue: (used, left) => `${used} utilisés · reste ${left}`,
    resetValue: (day, time, elapsed) => `${day} à ${time}  ·  ${elapsed} écoulé`,
    tooltipDay: (progress, used, budget) => `Claude · aujourd’hui ${progress} (${used} / ${budget})`,
    tooltipWeek: (used, day, time) => `Claude · semaine ${used} · remise à zéro ${day} à ${time}`,

    chartTitle: 'Usage Claude de la semaine',
    chartTitleRange: (first, last) => `Usage Claude — semaine du ${first} au ${last}`,
    chartSummary: (used, left, day, time) => `${used} utilisés · reste ${left} · remise à zéro ${day} à ${time}`,
    chartFooter: time => `En % de la limite hebdomadaire · mis à jour à ${time}`,
    close: 'Fermer',
    chartUntracked: 'non suivi',
    chartUntrackedDays: 'jours non suivis',
    chartTotal: total => `${total} au total`,
    chartToday: 'aujourd’hui',
    chartFrom: time => `dès ${time}`,
    chartUntil: time => `jusqu’à ${time}`,
    legendUsed: 'utilisé',
    legendBudget: 'budget du jour',
    legendOver: 'dépassement',
    legendPlanned: 'prévu',

    planItem: (day, budget) => `${day} : ${budget}`,
    planNone: time => `plus aucun jour avant la remise à zéro (${time})`,
    notifyOverTitle: 'Claude : budget du jour dépassé',
    notifyOverBody: (used, budget, extra, plan) =>
        `${used} utilisés pour ${budget} prévus aujourd’hui (+${extra}).\nBudgets recalculés : ${plan}`,
    notifyFullTitle: 'Claude : budget du jour atteint',
    notifyFullBody: (budget, plan) => `Vous avez utilisé les ${budget} prévus pour aujourd’hui.\nProchains jours : ${plan}`,
    notifyLevelTitle: level => `Claude : ${level} % du budget du jour`,
    notifyLevelBody: (used, budget, week) => `${used} utilisés sur ${budget} prévus aujourd’hui (semaine : ${week}).`,

    errNoLogin: 'Connexion Claude introuvable (~/.claude/.credentials.json)',
    errExpired: 'Connexion expirée : lancez Claude Code pour la renouveler',
    errTooMany: 'Trop de requêtes, nouvel essai dans 5 min',
    errHttp: status => `Service indisponible (HTTP ${status})`,
    errUnexpected: 'Réponse inattendue du service Claude',
};

const EN = {
    title: 'Claude Budget',
    today: 'Today',
    todayOf: day => `Today (${day})`,
    week: 'Week',
    reset: 'Resets',
    session: 'Session (5 h)',
    upcomingHeader: `Next days (weekend reserve ${WEEKEND_SHARE}%)`,
    lastDay: 'Last day before the reset',
    weekendSuffix: ' (weekend)',
    untilSuffix: time => ` (until ${time})`,
    updated: 'Updated',
    updatedViaCli: 'Updated (via claude /usage)',
    viewWeek: 'View the week…',
    refreshNow: 'Refresh now',
    quit: 'Quit',
    panelWeek: 'wk',
    todayValue: (used, budget, progress) => `${used} / ${budget}  ·  ${progress}`,
    weekValue: (used, left) => `${used} used · ${left} left`,
    resetValue: (day, time, elapsed) => `${day} at ${time}  ·  ${elapsed} elapsed`,
    tooltipDay: (progress, used, budget) => `Claude · today ${progress} (${used} / ${budget})`,
    tooltipWeek: (used, day, time) => `Claude · week ${used} · resets ${day} at ${time}`,

    chartTitle: 'Claude usage this week',
    chartTitleRange: (first, last) => `Claude usage — week of ${first} to ${last}`,
    chartSummary: (used, left, day, time) => `${used} used · ${left} left · resets ${day} at ${time}`,
    chartFooter: time => `In % of the weekly limit · updated at ${time}`,
    close: 'Close',
    chartUntracked: 'not tracked',
    chartUntrackedDays: 'days not tracked',
    chartTotal: total => `${total} in total`,
    chartToday: 'today',
    chartFrom: time => `from ${time}`,
    chartUntil: time => `until ${time}`,
    legendUsed: 'used',
    legendBudget: 'daily budget',
    legendOver: 'over budget',
    legendPlanned: 'planned',

    planItem: (day, budget) => `${day}: ${budget}`,
    planNone: time => `no day left before the reset (${time})`,
    notifyOverTitle: 'Claude: daily budget exceeded',
    notifyOverBody: (used, budget, extra, plan) =>
        `${used} used for ${budget} planned today (+${extra}).\nBudgets recalculated: ${plan}`,
    notifyFullTitle: 'Claude: daily budget reached',
    notifyFullBody: (budget, plan) => `You have used the ${budget} planned for today.\nNext days: ${plan}`,
    notifyLevelTitle: level => `Claude: ${level}% of today's budget`,
    notifyLevelBody: (used, budget, week) => `${used} used of ${budget} planned today (week: ${week}).`,

    errNoLogin: 'Claude login not found (~/.claude/.credentials.json)',
    errExpired: 'Login expired: open Claude Code to renew it',
    errTooMany: 'Too many requests, retrying in 5 min',
    errHttp: status => `Service unavailable (HTTP ${status})`,
    errUnexpected: 'Unexpected answer from the Claude service',
};

const TABLES = { fr: FR, en: EN };

/** Textes et formats d'une langue : t.pct(18.29) → « 18,3 % » / « 18.3% ». */
export function strings(lang) {
    const code = TABLES[lang] ? lang : 'en';
    return {
        ...TABLES[code],
        lang: code,
        pct: x => pctText(x, code),
        day: key => dayLabel(key, code),
    };
}
