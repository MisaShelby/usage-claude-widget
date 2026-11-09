// Calcul du budget quotidien de la limite hebdomadaire Claude.
// Module pur (aucun import GNOME) : testé avec node, chargé tel quel par GNOME Shell.
//
// Toutes les valeurs sont en % de la limite hebdomadaire (0–100).

/** Part de la semaine réservée au week-end (samedi + dimanche). */
export const WEEKEND_SHARE = 10;

const DAY_MS = 24 * 3600 * 1000;
const WEEK_MS = 7 * DAY_MS;
const DAY_NAMES = {
    fr: ['dim.', 'lun.', 'mar.', 'mer.', 'jeu.', 'ven.', 'sam.'],
    en: ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'],
};
const LEVELS = [25, 50, 75, 100, 'over'];

const sum = xs => xs.reduce((a, b) => a + b, 0);
const pad = n => String(n).padStart(2, '0');

/** Clé locale AAAA-MM-JJ du jour contenant `ms`. */
export function localKey(ms) {
    const d = new Date(ms);
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`;
}

/** `resets_at` de l'API (microsecondes, léger bruit) → timestamp arrondi à la minute. */
export function normalizeReset(iso) {
    const ms = Date.parse(iso.replace(/\.\d+/, ''));
    return Math.round(ms / 60000) * 60000;
}

/**
 * Jours calendaires (heure locale) d'aujourd'hui jusqu'au reset.
 * `weight` = fraction du jour comprise dans la fenêtre hebdomadaire
 * (le mardi du reset est partiel, des deux côtés).
 */
export function daysUntilReset(now, resetAt) {
    const windowStart = resetAt - WEEK_MS;
    const days = [];
    const cur = new Date(now);
    let dayStart = new Date(cur.getFullYear(), cur.getMonth(), cur.getDate()).getTime();
    while (dayStart < resetAt) {
        const d = new Date(dayStart);
        const dayEnd = new Date(d.getFullYear(), d.getMonth(), d.getDate() + 1).getTime();
        const overlap = Math.min(dayEnd, resetAt) - Math.max(dayStart, windowStart);
        if (overlap > 0) {
            days.push({
                key: localKey(dayStart),
                weekend: d.getDay() === 0 || d.getDay() === 6,
                weight: overlap / (dayEnd - dayStart),
            });
        }
        dayStart = dayEnd;
    }
    return days;
}

/**
 * Répartit `remaining` % entre `days` : chaque jour de week-end garde sa part
 * de WEEKEND_SHARE (5 % par jour), le reste va aux jours de semaine au prorata
 * de leur poids.
 */
export function allocate(remaining, days) {
    const rem = Math.max(0, remaining);
    const targets = days.map(d => (d.weekend ? (WEEKEND_SHARE / 2) * d.weight : 0));
    const targetSum = sum(targets);
    const reserve = Math.min(rem, targetSum);
    const pool = rem - reserve;
    const weekdayWeight = sum(days.filter(d => !d.weekend).map(d => d.weight));
    const weekendWeight = sum(days.filter(d => d.weekend).map(d => d.weight));

    return days.map((d, i) => {
        if (!d.weekend)
            return weekdayWeight > 0 ? (pool * d.weight) / weekdayWeight : 0;
        let budget = targetSum > 0 ? (targets[i] * reserve) / targetSum : 0;
        if (weekdayWeight === 0 && weekendWeight > 0)
            budget += (pool * d.weight) / weekendWeight;
        return budget;
    });
}

/**
 * État du jour.
 * - todayBudget : figé à partir de l'usage du début de journée (dayStartUtil)
 * - upcoming    : jours suivants recalculés avec l'usage actuel ; un dépassement
 *                 aujourd'hui réduit leur part, un reste non dépensé leur revient
 *                 le lendemain (nouveau budget calculé au changement de jour).
 */
export function computeStatus({ utilization, dayStartUtil, resetAt, now }) {
    const days = daysUntilReset(now, resetAt);
    const todayBudget = days.length ? allocate(100 - dayStartUtil, days)[0] : 0;
    const usedToday = Math.max(0, utilization - dayStartUtil);
    let progress;
    if (todayBudget > 0)
        progress = (usedToday / todayBudget) * 100;
    else
        progress = usedToday > 0 ? Infinity : 100;

    const leftoverToday = Math.max(0, todayBudget - usedToday);
    const future = days.slice(1);
    const budgets = allocate(100 - utilization - leftoverToday, future);
    const upcoming = future.map((d, i) => ({ ...d, budget: budgets[i] }));

    return { todayBudget, usedToday, progress, upcoming, today: days[0] ?? null };
}

/**
 * Paliers de notification (25/50/75/100 % du budget du jour, puis dépassement).
 * Ne renvoie que le palier le plus haut nouvellement franchi.
 */
export function checkThresholds(progress, notified) {
    const reached = LEVELS.filter(l => (l === 'over' ? progress > 100 : progress >= l));
    const fresh = reached.filter(l => !notified.includes(l));
    return {
        level: fresh.length ? fresh[fresh.length - 1] : null,
        notified: LEVELS.filter(l => notified.includes(l) || reached.includes(l)),
    };
}

/**
 * Nouveau jour ou nouvelle semaine → on repart de l'usage actuel.
 * L'historique des jours est conservé jusqu'à la remise à zéro hebdomadaire.
 * Une remise à zéro décalée de quelques minutes (API exacte ↔ /usage arrondi)
 * reste la même semaine : on adopte simplement la nouvelle heure.
 */
export function rollDayState(state, { utilization, resetAt, now }) {
    const dayKey = localKey(now);
    const sameWeek = Boolean(state) && sameReset(state.resetAt, resetAt);
    if (sameWeek && state.dayKey === dayKey)
        return state.resetAt === resetAt ? state : { ...state, resetAt };
    const history = sameWeek ? (state.history ?? {}) : {};
    return { dayKey, resetAt, dayStartUtil: utilization, notified: [], history };
}

// ── Secours : la commande `/usage` de Claude Code ─────────────────────────────
// Quand le jeton de ~/.claude/.credentials.json a expiré (Claude Code fermé),
// l'API refuse ; `claude -p /usage` renouvelle la connexion lui-même et affiche :
//   Current session: 2% used · resets Nov 9, 1:10pm (Europe/Paris)
//   Current week (all models): 49% used · resets Nov 10, 3pm (Europe/Paris)
// L'heure y est arrondie (« 7:59pm » puis « 8pm ») : on la cale sur la remise à
// zéro déjà connue quand elle en est proche (idée reprise du plugin weekly-budget).

const MIN_MS = 60 * 1000;
const RESET_MATCH_MS = 90 * MIN_MS;
const RESET_ROUND_MS = 5 * MIN_MS;
const MONTHS = ['jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'];
const WEEK_TEXT = /^Current week \(all models\):\s*(\d+(?:\.\d+)?)\s*%\s*used(.*)$/im;
const SESSION_TEXT = /^Current session:\s*(\d+(?:\.\d+)?)\s*%\s*used/im;
const RESET_TEXT = /resets\s+([A-Za-z]{3})[a-z]*\.?\s+(\d{1,2}),?\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)?/i;

function sameReset(a, b) {
    return Number.isFinite(a) && Number.isFinite(b) && Math.abs(a - b) <= RESET_MATCH_MS;
}

/** « resets Nov 10, 3pm » (heure locale) → timestamp arrondi à 5 min, ou null. */
function parseResetText(text, now) {
    const m = RESET_TEXT.exec(text);
    if (!m)
        return null;
    const month = MONTHS.indexOf(m[1].toLowerCase());
    let hour = Number(m[3]);
    const minute = Number(m[4] ?? 0);
    if (m[5])
        hour = (hour % 12) + (m[5].toLowerCase() === 'pm' ? 12 : 0);
    if (month < 0 || hour > 23 || minute > 59)
        return null;
    const year = new Date(now).getFullYear();
    const ms = [year, year + 1]
        .map(y => new Date(y, month, Number(m[2]), hour, minute).getTime())
        .find(t => t > now - RESET_MATCH_MS && t <= now + WEEK_MS + DAY_MS);
    return ms === undefined ? null : Math.round(ms / RESET_ROUND_MS) * RESET_ROUND_MS;
}

/**
 * Texte de `claude -p /usage` → { utilization, session, resetAt } (resetAt null si
 * illisible), ou null sans ligne « Current week » valable.
 */
export function parseUsageText(text, now) {
    const week = WEEK_TEXT.exec(text);
    if (!week)
        return null;
    const utilization = Number(week[1]);
    if (!(utilization >= 0 && utilization <= 100))
        return null;
    const session = SESSION_TEXT.exec(text);
    return {
        utilization,
        session: session ? Number(session[1]) : null,
        resetAt: parseResetText(week[2], now),
    };
}

/**
 * Remise à zéro à retenir pour une lecture de /usage : la connue (exacte, venue de
 * l'API) si la semaine court encore et que /usage en annonce une voisine ou aucune ;
 * sinon celle lue dans /usage (nouvelle semaine) ; null si aucune n'est sûre.
 */
export function pickReset(known, candidate, now) {
    const live = Number.isFinite(known) && known > now ? known : null;
    if (candidate === null)
        return live;
    return live !== null && sameReset(live, candidate) ? live : candidate;
}

/** Enregistre dans l'historique le budget et l'usage du jour en cours. */
export function recordDay(state, { todayBudget, usedToday }) {
    return {
        ...state,
        history: {
            ...(state.history ?? {}),
            [state.dayKey]: { budget: todayBudget, start: state.dayStartUtil, used: usedToday },
        },
    };
}

/**
 * Données du graphique de la semaine (mardi du reset précédent → mardi du reset).
 * - days : un élément par jour calendaire, `kind` = past | today | future | gap
 *          (gap = jour passé sans relevé : PC éteint ou suivi pas encore démarré)
 * - gaps : suites de jours sans relevé, avec le total consommé pendant ce temps
 *          (début du relevé suivant − fin du relevé précédent).
 */
export function weekChart({ state, status, resetAt }) {
    const history = state.history ?? {};
    const planned = new Map(status.upcoming.map(d => [d.key, d.budget]));
    const days = [];
    const gaps = [];
    let prevEnd = 0;
    let open = null;
    const closeGap = nextStart => {
        if (open) {
            gaps.push({ ...open, total: Math.max(0, nextStart - prevEnd) });
            open = null;
        }
    };

    daysUntilReset(resetAt - WEEK_MS, resetAt).forEach((d, i) => {
        const base = { key: d.key, weight: d.weight, weekend: d.weekend };
        if (d.key === state.dayKey) {
            closeGap(state.dayStartUtil);
            days.push({ ...base, kind: 'today', budget: status.todayBudget, used: status.usedToday });
        } else if (d.key > state.dayKey) {
            days.push({ ...base, kind: 'future', budget: planned.get(d.key) ?? 0, used: null });
        } else if (history[d.key]) {
            const r = history[d.key];
            closeGap(r.start);
            prevEnd = r.start + r.used;
            days.push({ ...base, kind: 'past', budget: r.budget, used: r.used });
        } else {
            if (open)
                open.to = i;
            else
                open = { from: i, to: i };
            days.push({ ...base, kind: 'gap', budget: null, used: null });
        }
    });
    return { days, gaps };
}

const STEPS = [0.5, 1, 2, 2.5, 5, 10, 20, 25, 50, 100];

/** Échelle ronde de l'axe vertical : au plus 4 graduations au-dessus de 0. */
export function chartScale(maxValue) {
    if (!(maxValue > 0))
        return { max: 5, step: 5 };
    const step = STEPS.find(s => Math.ceil(maxValue / s) <= 4) ?? 100;
    return { max: Math.ceil(maxValue / step) * step, step };
}

/** Texte à côté de la barre du haut : % du budget du jour (arrondi). */
export function progressText(progress, lang = 'fr') {
    if (Number.isFinite(progress))
        return pctText(Math.round(progress), lang);
    return lang === 'fr' ? 'dépassé' : 'over';
}

/** Remplissage de la barre du haut (0 → 1), pleine une fois le budget atteint. */
export function barFraction(progress) {
    if (!Number.isFinite(progress))
        return 1;
    return Math.min(1, Math.max(0, progress / 100));
}

/** Couleur d'une barre de progression (en %) : vert sous 50 %, orange de 50 à 75 %, rouge dès 75 %. */
export function barLevel(percent) {
    if (!Number.isFinite(percent) || percent >= 75)
        return 'red';
    return percent >= 50 ? 'orange' : 'green';
}

/** Part écoulée de la semaine de quota (0 → 1), du reset précédent au prochain. */
export function weekElapsed(now, resetAt) {
    return Math.min(1, Math.max(0, 1 - (resetAt - now) / WEEK_MS));
}

/**
 * Longueur des barres des jours à venir (0 → 1) : budget prévu rapporté au plus
 * gros budget de la liste, celui d'aujourd'hui compris.
 */
export function planFractions(todayBudget, upcoming) {
    const max = Math.max(todayBudget, ...upcoming.map(d => d.budget));
    return upcoming.map(d => (max > 0 ? d.budget / max : 0));
}

/** 18.2857 → "18,3" (fr) ou "18.3" (en) ; 5 → "5". */
export function fmtPct(x, lang = 'fr') {
    const r = Math.round(x * 10) / 10;
    const s = String(r === 0 ? 0 : r);
    return lang === 'fr' ? s.replace('.', ',') : s;
}

/** 18.2857 → "18,3 %" (fr) ou "18.3%" (en). */
export function pctText(x, lang = 'fr') {
    return lang === 'fr' ? `${fmtPct(x, lang)} %` : `${fmtPct(x, lang)}%`;
}

/** "2026-11-07" → "sam. 7" (fr) ou "Sat 7" (en). */
export function dayLabel(key, lang = 'fr') {
    const [y, m, d] = key.split('-').map(Number);
    const names = DAY_NAMES[lang] ?? DAY_NAMES.en;
    return `${names[new Date(y, m - 1, d).getDay()]} ${d}`;
}
