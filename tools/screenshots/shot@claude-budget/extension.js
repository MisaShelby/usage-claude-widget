import GLib from 'gi://GLib';
import Gio from 'gi://Gio';
import Shell from 'gi://Shell';
// Captures d'écran du widget GNOME pour le README (lancé par tools/screenshots/linux.sh).
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';

const OUT = GLib.getenv('SHOT_DIR');
const write = (name, text) => GLib.file_set_contents(`${OUT}/${name}`, text);
const wait = ms => new Promise(r => GLib.timeout_add(GLib.PRIORITY_DEFAULT, ms, () => { r(); return GLib.SOURCE_REMOVE; }));

async function shoot(name) {
    const file = Gio.File.new_for_path(`${OUT}/${name}.png`);
    const stream = file.replace(null, false, Gio.FileCreateFlags.NONE, null);
    const shooter = new Shell.Screenshot();
    await new Promise((res, rej) => shooter.screenshot(false, stream, (s, r) => {
        try { s.screenshot_finish(r); res(); } catch (e) { rej(e); }
    }));
    stream.close(null);
}

const bounds = actor => {
    const [x, y] = actor.get_transformed_position();
    const [w, h] = actor.get_transformed_size();
    return {x: Math.round(x), y: Math.round(y), w: Math.round(w), h: Math.round(h)};
};

// Même semaine d'exemple que le mode -Demo de Windows (Get-DemoUsage dans windows/ClaudeBudget.ps1).
function demo(B) {
    const now = Date.now();
    const d = new Date(now);
    const todayKey = B.localKey(now);
    const resetAt = new Date(d.getFullYear(), d.getMonth(), d.getDate() + 4, 15, 0).getTime();
    const windowStart = resetAt - 7 * 24 * 3600 * 1000;
    const factors = [0.8, 1.18, 0.82, 0.9, 1.05, 0.7];
    const round1 = x => Math.round(x * 10) / 10;
    const history = {};
    let start = 0;
    let i = 0;
    for (const day of B.daysUntilReset(windowStart, resetAt)) {
        if (day.key >= todayKey)
            break;
        const [y, m, dd] = day.key.split('-').map(Number);
        const midnight = new Date(y, m - 1, dd).getTime();
        const budget = B.allocate(100 - start, B.daysUntilReset(Math.max(midnight, windowStart), resetAt))[0];
        const used = round1(budget * factors[i % factors.length]);
        history[day.key] = {budget: round1(budget), start: round1(start), used};
        start += used;
        i++;
    }
    const dayStart = round1(start);
    const state = {dayKey: todayKey, resetAt, dayStartUtil: dayStart, notified: [25, 50], history};
    const first = B.computeStatus({utilization: dayStart, dayStartUtil: dayStart, resetAt, now});
    const utilization = round1(dayStart + 0.62 * first.todayBudget);
    return {state, usage: {utilization, resetAt, session: 23, source: 'api'}, now};
}

export default class Shot extends Extension {
    enable() {
        (async () => {
            const info = {};
            try {
                Main.overview.hide();
                const ext = Main.extensionManager.lookup('claude-budget@misashelby');
                let obj = null;
                for (let i = 0; i < 60; i++) { // attend la fin du premier relevé (en échec : pas de compte ici)
                    await wait(500);
                    obj = ext?.stateObj;
                    if (obj?._indicator && !obj._busy && obj._state !== undefined)
                        break;
                }
                const B = await import(`file://${ext.path}/budget.js`);
                const {state, usage, now} = demo(B);
                obj._state = state;
                obj._apply(usage, now);
                const ind = obj._indicator;
                await wait(1500);
                info.panel = bounds(ind);
                await shoot('topbar');
                ind.menu.open();
                await wait(1200);
                info.menu = bounds(ind.menu.actor ?? ind.menu.box);
                await shoot('menu');
                ind.menu.close();
                await wait(600);
                obj._openWeek();
                await wait(2000);
                info.week = bounds(obj._dialog.dialogLayout);
                await shoot('week');
                info.labels = {jour: ind._label.text, semaine: ind._weekLabel.text, maj: ind._updated.key.text};
            } catch (e) {
                info.error = `${e}\n${e.stack}`;
            } finally {
                write('info.json', JSON.stringify(info, null, 2));
                write('done', 'ok');
            }
        })();
    }
    disable() {}
}
