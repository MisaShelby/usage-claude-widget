// Budget Claude — indicateur GNOME Shell (barre du haut).
// Une barre se remplit jusqu'au budget du jour (part de la limite hebdomadaire
// Claude, 10 % gardés pour le week-end) ; notifications à 25/50/75/100 % et au
// dépassement ; graphique de l'usage par jour de la semaine dans une fenêtre.
// À droite du % du jour : « sem. 49 % », l'usage de la semaine. Si l'API refuse
// (jeton expiré), l'usage est relevé avec `claude -p /usage`.

import GLib from 'gi://GLib';
import Gio from 'gi://Gio';
import GObject from 'gi://GObject';
import St from 'gi://St';
import Clutter from 'gi://Clutter';
import Pango from 'gi://Pango';
import Soup from 'gi://Soup?version=3.0';

import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import * as PopupMenu from 'resource:///org/gnome/shell/ui/popupMenu.js';
import * as MessageTray from 'resource:///org/gnome/shell/ui/messageTray.js';
import * as ModalDialog from 'resource:///org/gnome/shell/ui/modalDialog.js';
import * as Dialog from 'resource:///org/gnome/shell/ui/dialog.js';

import * as B from './budget.js';
import {strings, pickLang} from './strings.js';
import {drawWeekChart} from './chart.js';

const USAGE_URL = 'https://api.anthropic.com/api/oauth/usage';
const REFRESH_SECONDS = 300;
const RETRY_SECONDS = 30; // réseau pas encore prêt (ouverture de session, Wi-Fi…)
const LOG = '[claude-budget]';

// Secours quand l'API refuse (jeton expiré, Claude Code fermé…) : la commande
// `/usage` de Claude Code, sans requête au modèle ni session enregistrée (comme le
// plugin weekly-budget). WEEKLY_BUDGET_PROBE empêche ce plugin, s'il est installé,
// de relancer lui-même /usage depuis ce Claude Code.
const PROBE_ARGS = ['-p', '--no-session-persistence', '--strict-mcp-config', '/usage'];
const PROBE_TIMEOUT_SECONDS = 60;
const PROBE_MIN_SECONDS = 240; // au plus une fois par actualisation (5 min)

const pad = n => String(n).padStart(2, '0');
const hhmm = ms => {
    const d = new Date(ms);
    return `${pad(d.getHours())}:${pad(d.getMinutes())}`;
};
// Textes dans la langue du système (fixée à l'activation de l'extension).
let T = strings('en');
const pct = x => T.pct(x);

function isCancelled(e) {
    return e instanceof GLib.Error && e.matches(Gio.IOErrorEnum, Gio.IOErrorEnum.CANCELLED);
}

function infoRow(title) {
    const item = new PopupMenu.PopupBaseMenuItem({reactive: false, can_focus: false});
    const key = new St.Label({text: title, x_expand: true, style_class: 'claude-budget-key'});
    const value = new St.Label({text: '—', style_class: 'claude-budget-value'});
    item.add_child(key);
    item.add_child(value);
    return {item, key, value};
}

const LEVELS = ['green', 'orange', 'red']; // voir B.barLevel
const LINE_STYLES = [...LEVELS, 'time'];

// Barre de progression remplie depuis la gauche : par défaut sur toute la largeur
// d'une ligne du menu, ou piste de largeur fixe dans la barre du haut. La longueur
// du remplissage est recalculée à chaque allocation (largeur du menu variable).
const ProgressLine = GObject.registerClass(
class ProgressLine extends St.Widget {
    _init(params = {}) {
        super._init({style_class: 'claude-budget-line', x_expand: true, ...params});
        this._fraction = 0;
        this._fill = new St.Widget({style_class: 'claude-budget-line-fill', visible: false});
        this.add_child(this._fill);
    }

    /** fraction : 0 → 1 (au-delà : barre pleine) ; style : un de LINE_STYLES. */
    setValue(fraction, style) {
        this._fraction = Number.isFinite(fraction) ? Math.min(1, Math.max(0, fraction)) : 1;
        for (const s of LINE_STYLES)
            this._fill.remove_style_class_name(`claude-budget-line-${s}`);
        this._fill.add_style_class_name(`claude-budget-line-${style}`);
        this._fill.visible = this._fraction > 0;
        this.queue_relayout();
    }

    vfunc_allocate(box) {
        this.set_allocation(box);
        const content = this.get_theme_node().get_content_box(box);
        const [width, height] = content.get_size();
        let w = Math.round(width * this._fraction);
        if (this._fraction > 0) // une toute petite valeur reste visible (bouts arrondis)
            w = Math.min(width, Math.max(w, height));
        const fill = new Clutter.ActorBox();
        fill.set_origin(content.x1, content.y1);
        fill.set_size(w, height);
        this._fill.allocate(fill);
    }
});

/** Ligne du menu : libellé et valeur, avec une barre de progression en dessous. */
function barRow(title) {
    const item = new PopupMenu.PopupBaseMenuItem({
        reactive: false,
        can_focus: false,
        style_class: 'claude-budget-bar-item',
    });
    const box = new St.BoxLayout({
        orientation: Clutter.Orientation.VERTICAL,
        x_expand: true,
        style_class: 'claude-budget-row',
    });
    const line = new St.BoxLayout({x_expand: true});
    const key = new St.Label({text: title, x_expand: true, style_class: 'claude-budget-key'});
    const value = new St.Label({text: '—', style_class: 'claude-budget-value'});
    line.add_child(key);
    line.add_child(value);
    const bar = new ProgressLine();
    box.add_child(line);
    box.add_child(bar);
    item.add_child(box);
    return {item, key, value, bar};
}

const BudgetIndicator = GObject.registerClass(
class BudgetIndicator extends PanelMenu.Button {
    _init() {
        super._init(0.5, T.title);

        this._box = new St.BoxLayout({style_class: 'panel-status-menu-box'});
        this._box.add_child(new St.Icon({
            icon_name: 'power-profile-balanced-symbolic',
            style_class: 'system-status-icon',
        }));
        this._bar = new ProgressLine({
            style_class: 'claude-budget-track',
            x_expand: false,
            y_align: Clutter.ActorAlign.CENTER,
        });
        this._box.add_child(this._bar);
        this._label = new St.Label({
            text: '…',
            y_align: Clutter.ActorAlign.CENTER,
            style_class: 'claude-budget-label',
        });
        this._box.add_child(this._label);
        // « · sem. 49 % » : usage de la semaine, coloré selon la même règle.
        this._box.add_child(new St.Label({
            text: `·  ${T.panelWeek}`,
            y_align: Clutter.ActorAlign.CENTER,
            style_class: 'claude-budget-week-key',
        }));
        this._weekLabel = new St.Label({
            text: '…',
            y_align: Clutter.ActorAlign.CENTER,
            style_class: 'claude-budget-week-label',
        });
        this._box.add_child(this._weekLabel);
        this.add_child(this._box);

        this._today = barRow(T.today);
        this._week = barRow(T.week);
        this._reset = barRow(T.reset);
        this._session = barRow(T.session);
        for (const row of [this._today, this._week, this._reset, this._session])
            this.menu.addMenuItem(row.item);

        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem(T.upcomingHeader));
        this._plan = new PopupMenu.PopupMenuSection();
        this.menu.addMenuItem(this._plan);

        this.menu.addMenuItem(new PopupMenu.PopupSeparatorMenuItem());
        this._updated = infoRow(T.updated);
        this.menu.addMenuItem(this._updated.item);
        this.weekItem = new PopupMenu.PopupMenuItem(T.viewWeek);
        this.menu.addMenuItem(this.weekItem);
        this.refreshItem = new PopupMenu.PopupMenuItem(T.refreshNow);
        this.menu.addMenuItem(this.refreshItem);

        this._hasData = false;
    }

    showStatus(status, usage, now) {
        this._hasData = true;
        const {todayBudget, usedToday, progress, upcoming, today} = status;

        this._label.text = B.progressText(progress, T.lang);
        const level = B.barLevel(progress);
        this._bar.setValue(B.barFraction(progress), level);
        for (const l of LEVELS) // couleur du « % » à côté de la barre
            this._box.remove_style_class_name(`claude-budget-${l}`);
        this._box.add_style_class_name(`claude-budget-${level}`);

        const weekLevel = B.barLevel(usage.utilization);
        this._weekLabel.text = B.progressText(usage.utilization, T.lang);
        for (const l of LEVELS)
            this._weekLabel.remove_style_class_name(`claude-budget-week-${l}`);
        this._weekLabel.add_style_class_name(`claude-budget-week-${weekLevel}`);

        this._today.key.text = today ? T.todayOf(T.day(today.key)) : T.today;
        this._today.value.text = T.todayValue(B.fmtPct(usedToday, T.lang), pct(todayBudget), B.progressText(progress, T.lang));
        this._today.bar.setValue(B.barFraction(progress), level);

        this._week.value.text = T.weekValue(pct(usage.utilization), pct(100 - usage.utilization));
        this._week.bar.setValue(usage.utilization / 100, weekLevel);

        const elapsed = B.weekElapsed(now, usage.resetAt);
        this._reset.value.text = T.resetValue(T.day(B.localKey(usage.resetAt)), hhmm(usage.resetAt), pct(Math.round(elapsed * 100)));
        this._reset.bar.setValue(elapsed, 'time');

        if (usage.session === null) {
            this._session.value.text = '—';
            this._session.bar.setValue(0, 'green');
        } else {
            this._session.value.text = pct(usage.session);
            this._session.bar.setValue(usage.session / 100, B.barLevel(usage.session));
        }

        this._plan.removeAll();
        if (upcoming.length === 0) {
            const row = infoRow(T.lastDay);
            row.value.text = '';
            this._plan.addMenuItem(row.item);
        }
        const lengths = B.planFractions(todayBudget, upcoming);
        upcoming.forEach((day, i) => {
            let title = T.day(day.key);
            if (day.weekend)
                title += T.weekendSuffix;
            else if (day.weight < 1)
                title += T.untilSuffix(hhmm(usage.resetAt));
            const row = barRow(title);
            row.value.text = pct(day.budget);
            row.bar.setValue(lengths[i], B.barLevel(lengths[i] * 100)); // couleur selon le remplissage
            this._plan.addMenuItem(row.item);
        });

        this._updated.key.text = usage.source === 'cli' ? T.updatedViaCli : T.updated;
        this._updated.value.text = hhmm(now);
    }

    showError(message) {
        if (!this._hasData) {
            this._label.text = '⚠';
            this._weekLabel.text = '—';
        }
        this._updated.key.text = `⚠ ${message}`;
        this._updated.value.text = hhmm(Date.now());
    }
});

const WeekDialog = GObject.registerClass(
class WeekDialog extends ModalDialog.ModalDialog {
    _init() {
        super._init({styleClass: 'claude-budget-dialog', destroyOnClose: true});
        this._data = null;

        this._header = new Dialog.MessageDialogContent({title: T.chartTitle});
        this.contentLayout.add_child(this._header);

        this._area = new St.DrawingArea({style_class: 'claude-budget-chart', x_align: Clutter.ActorAlign.CENTER});
        this._area.connect('repaint', area => this._repaint(area));
        this.contentLayout.add_child(this._area);

        this._footer = new St.Label({style_class: 'claude-budget-chart-footer', x_align: Clutter.ActorAlign.CENTER});
        this.contentLayout.add_child(this._footer);

        this.setButtons([{
            label: T.close,
            action: () => this.close(),
            key: Clutter.KEY_Escape,
            default: true,
        }]);
    }

    update({chart, usage, now}) {
        this._data = {chart, resetTime: hhmm(usage.resetAt)};
        const first = chart.days[0]?.key;
        const last = chart.days[chart.days.length - 1]?.key;
        if (first && last)
            this._header.title = T.chartTitleRange(T.day(first), T.day(last));
        this._header.description = T.chartSummary(pct(usage.utilization), pct(100 - usage.utilization),
            T.day(B.localKey(usage.resetAt)), hhmm(usage.resetAt));
        this._footer.text = T.chartFooter(hhmm(now));
        this._area.queue_repaint();
    }

    _repaint(area) {
        const cr = area.get_context();
        try {
            if (!this._data)
                return;
            const node = area.get_theme_node();
            const fg = node.get_foreground_color();
            const font = node.get_font();
            const size = font.get_size() / Pango.SCALE;
            const fontPx = font.get_size_is_absolute() ? size : size * 96 / 72;
            const scale = St.ThemeContext.get_for_stage(global.stage).scale_factor;
            const [w, h] = area.get_surface_size();
            cr.scale(scale, scale);
            drawWeekChart(cr, w / scale, h / scale, this._data.chart, {
                fg: [fg.red / 255, fg.green / 255, fg.blue / 255],
                fontFamily: font.get_family() ?? 'Sans',
                fontPx: fontPx > 0 ? fontPx : 14,
                resetTime: this._data.resetTime,
                t: T,
            });
        } catch (e) {
            console.warn(`${LOG} graphique : ${e.message}`);
        } finally {
            cr.$dispose();
        }
    }
});

export default class ClaudeBudgetExtension extends Extension {
    enable() {
        T = strings(pickLang(GLib.get_language_names()));
        this._cancellable = new Gio.Cancellable();
        this._http = new Soup.Session({timeout: 20, user_agent: 'claude-budget-gnome-extension/1'});
        this._credPath = GLib.build_filenamev([GLib.get_home_dir(), '.claude', '.credentials.json']);
        this._statePath = GLib.build_filenamev([GLib.get_user_state_dir(), 'claude-budget', 'state.json']);
        this._state = undefined;
        this._savedJson = null;
        this._busy = false;
        this._proc = null;
        this._probedAt = 0;

        this._indicator = new BudgetIndicator();
        this._indicator.refreshItem.connect('activate', () => this._refresh());
        this._indicator.weekItem.connect('activate', () => this._openWeek());
        this._last = null;
        this._dialog = null;
        Main.panel.addToStatusArea(this.uuid, this._indicator, 0, 'right');

        this._timerId = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, REFRESH_SECONDS, () => {
            this._refresh();
            return GLib.SOURCE_CONTINUE;
        });
        this._refresh();
    }

    disable() {
        if (this._timerId) {
            GLib.source_remove(this._timerId);
            this._timerId = 0;
        }
        if (this._retryId) {
            GLib.source_remove(this._retryId);
            this._retryId = 0;
        }
        this._cancellable.cancel();
        this._cancellable = null;
        this._proc?.force_exit();
        this._proc = null;
        this._http.abort();
        this._http = null;
        this._dialog?.destroy();
        this._dialog = null;
        this._last = null;
        this._indicator.destroy();
        this._indicator = null;
        this._state = undefined;
    }

    async _refresh() {
        if (this._busy)
            return;
        this._busy = true;
        try {
            if (this._state === undefined)
                this._state = await this._loadState();
            const usage = await this._fetchUsage();
            if (!this._indicator)
                return;
            this._apply(usage, Date.now());
        } catch (e) {
            if (isCancelled(e) || !this._indicator)
                return;
            console.warn(`${LOG} ${e.message}`);
            this._indicator.showError(e.message);
            if (e instanceof GLib.Error)
                this._scheduleRetry();
        } finally {
            this._busy = false;
        }
    }

    _scheduleRetry() {
        if (this._retryId)
            return;
        this._retryId = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, RETRY_SECONDS, () => {
            this._retryId = 0;
            this._refresh();
            return GLib.SOURCE_REMOVE;
        });
    }

    _apply(usage, now) {
        this._state = B.rollDayState(this._state, {utilization: usage.utilization, resetAt: usage.resetAt, now});
        const status = B.computeStatus({
            utilization: usage.utilization,
            dayStartUtil: this._state.dayStartUtil,
            resetAt: usage.resetAt,
            now,
        });
        const {level, notified} = B.checkThresholds(status.progress, this._state.notified);
        if (level !== null) {
            this._state = {...this._state, notified};
            this._notify(level, status, usage);
        }
        this._state = B.recordDay(this._state, status);
        this._saveState();
        this._indicator.showStatus(status, usage, now);
        this._last = {status, usage, now};
        this._updateWeek();
        console.debug(`${LOG} semaine=${usage.utilization} début=${this._state.dayStartUtil} ` +
            `budget=${status.todayBudget.toFixed(2)} utilisé=${status.usedToday} ` +
            `progression=${status.progress.toFixed(1)} palier=${level}`);
    }

    _openWeek() {
        if (!this._dialog) {
            this._dialog = new WeekDialog();
            this._dialog.connect('destroy', () => {
                this._dialog = null;
            });
        }
        this._updateWeek();
        this._dialog.open();
    }

    _updateWeek() {
        if (!this._dialog || !this._last)
            return;
        const {status, usage, now} = this._last;
        const chart = B.weekChart({state: this._state, status, resetAt: usage.resetAt});
        this._dialog.update({chart, usage, now});
    }

    _notify(level, status, usage) {
        const used = pct(status.usedToday);
        const budget = pct(status.todayBudget);
        const plan = status.upcoming.length
            ? status.upcoming.map(d => T.planItem(T.day(d.key), pct(d.budget))).join(' · ')
            : T.planNone(hhmm(usage.resetAt));

        let title, body, urgency = MessageTray.Urgency.NORMAL;
        if (level === 'over') {
            title = T.notifyOverTitle;
            body = T.notifyOverBody(used, budget, pct(status.usedToday - status.todayBudget), plan);
            urgency = MessageTray.Urgency.HIGH;
        } else if (level === 100) {
            title = T.notifyFullTitle;
            body = T.notifyFullBody(budget, plan);
            urgency = MessageTray.Urgency.HIGH;
        } else {
            title = T.notifyLevelTitle(level);
            body = T.notifyLevelBody(used, budget, pct(usage.utilization));
        }

        const source = MessageTray.getSystemSource();
        source.addNotification(new MessageTray.Notification({source, title, body, urgency}));
    }

    /** L'API d'abord ; si elle refuse, la commande /usage de Claude Code. */
    async _fetchUsage() {
        try {
            return await this._fetchFromApi();
        } catch (e) {
            if (isCancelled(e) || Date.now() - this._probedAt < PROBE_MIN_SECONDS * 1000)
                throw e;
            this._probedAt = Date.now();
            try {
                const usage = await this._probeUsage();
                console.debug(`${LOG} API : ${e.message} → relevé via claude /usage`);
                return usage;
            } catch (probeError) {
                if (isCancelled(probeError))
                    throw probeError;
                console.warn(`${LOG} claude /usage : ${probeError.message}`);
                throw e; // le message de l'API reste le plus parlant
            }
        }
    }

    async _probeUsage() {
        const claude = this._claudePath();
        if (!claude)
            throw new Error('commande claude introuvable');
        const launcher = new Gio.SubprocessLauncher({
            flags: Gio.SubprocessFlags.STDIN_PIPE | Gio.SubprocessFlags.STDOUT_PIPE |
                Gio.SubprocessFlags.STDERR_SILENCE,
        });
        launcher.setenv('WEEKLY_BUDGET_PROBE', '1', true);
        // GNOME Shell n'a pas ~/.local/bin dans son PATH.
        launcher.setenv('PATH', `${GLib.path_get_dirname(claude)}:${GLib.getenv('PATH') ?? '/usr/bin:/bin'}`, true);
        launcher.set_cwd(GLib.get_home_dir());
        const proc = launcher.spawnv([claude, ...PROBE_ARGS]);
        this._proc = proc;
        let timeoutId = GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, PROBE_TIMEOUT_SECONDS, () => {
            timeoutId = 0;
            proc.force_exit();
            return GLib.SOURCE_REMOVE;
        });
        try {
            const stdout = await new Promise((resolve, reject) => {
                proc.communicate_utf8_async(null, this._cancellable, (p, res) => {
                    try {
                        resolve(p.communicate_utf8_finish(res)[1] ?? '');
                    } catch (err) {
                        reject(err);
                    }
                });
            });
            if (!proc.get_successful())
                throw new Error(timeoutId ? `code de sortie ${proc.get_exit_status()}` : 'trop long, arrêté');
            const now = Date.now();
            const parsed = B.parseUsageText(stdout, now);
            if (!parsed)
                throw new Error(`réponse inattendue : ${stdout.trim().split('\n')[0] ?? ''}`);
            const resetAt = B.pickReset(this._state?.resetAt, parsed.resetAt, now);
            if (resetAt === null)
                throw new Error('date de remise à zéro illisible');
            return {utilization: parsed.utilization, resetAt, session: parsed.session, source: 'cli'};
        } finally {
            if (timeoutId)
                GLib.source_remove(timeoutId);
            if (this._proc === proc)
                this._proc = null;
        }
    }

    _claudePath() {
        const home = GLib.get_home_dir();
        return [
            GLib.find_program_in_path('claude'),
            GLib.build_filenamev([home, '.local', 'bin', 'claude']),
            GLib.build_filenamev([home, '.claude', 'local', 'claude']),
        ].find(p => p && GLib.file_test(p, GLib.FileTest.IS_EXECUTABLE)) ?? null;
    }

    async _fetchFromApi() {
        let creds;
        try {
            creds = JSON.parse(await this._readText(this._credPath))?.claudeAiOauth;
        } catch (e) {
            if (isCancelled(e))
                throw e;
            throw new Error(T.errNoLogin);
        }
        if (!creds?.accessToken)
            throw new Error(T.errNoLogin);
        if (creds.expiresAt && creds.expiresAt < Date.now())
            throw new Error(T.errExpired);

        const {status, text} = await this._get(USAGE_URL, {
            'Authorization': `Bearer ${creds.accessToken}`,
            'anthropic-beta': 'oauth-2025-04-20',
            'Accept': 'application/json',
        });
        if (status === 401)
            throw new Error(T.errExpired);
        if (status === 429)
            throw new Error(T.errTooMany);
        if (status !== 200)
            throw new Error(T.errHttp(status));

        const data = JSON.parse(text);
        const week = data?.seven_day;
        if (typeof week?.utilization !== 'number' || !week.resets_at)
            throw new Error(T.errUnexpected);
        return {
            utilization: week.utilization,
            resetAt: B.normalizeReset(week.resets_at),
            session: typeof data.five_hour?.utilization === 'number' ? data.five_hour.utilization : null,
            source: 'api',
        };
    }

    _get(url, headers) {
        const msg = Soup.Message.new('GET', url);
        const reqHeaders = msg.get_request_headers();
        for (const [name, value] of Object.entries(headers))
            reqHeaders.append(name, value);
        return new Promise((resolve, reject) => {
            this._http.send_and_read_async(msg, GLib.PRIORITY_DEFAULT, this._cancellable, (session, res) => {
                try {
                    const bytes = session.send_and_read_finish(res);
                    const raw = bytes.get_data() ?? new Uint8Array();
                    resolve({status: msg.get_status(), text: new TextDecoder().decode(raw)});
                } catch (e) {
                    reject(e);
                }
            });
        });
    }

    _readText(path) {
        return new Promise((resolve, reject) => {
            Gio.File.new_for_path(path).load_contents_async(this._cancellable, (file, res) => {
                try {
                    const [, contents] = file.load_contents_finish(res);
                    resolve(new TextDecoder().decode(contents));
                } catch (e) {
                    reject(e);
                }
            });
        });
    }

    async _loadState() {
        try {
            const json = await this._readText(this._statePath);
            this._savedJson = json;
            return JSON.parse(json);
        } catch (e) {
            if (isCancelled(e))
                throw e;
            return null;
        }
    }

    _saveState() {
        const json = JSON.stringify(this._state);
        if (json === this._savedJson)
            return;
        this._savedJson = json;
        const file = Gio.File.new_for_path(this._statePath);
        GLib.mkdir_with_parents(file.get_parent().get_path(), 0o700);
        const bytes = new GLib.Bytes(new TextEncoder().encode(json));
        file.replace_contents_bytes_async(bytes, null, false, Gio.FileCreateFlags.REPLACE_DESTINATION,
            null, (f, res) => {
                try {
                    f.replace_contents_finish(res);
                } catch (e) {
                    console.warn(`${LOG} état non enregistré : ${e.message}`);
                }
            });
    }
}
