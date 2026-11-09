// Dessin Cairo du graphique « usage par jour » de la semaine de quota.
// Aucun import GNOME Shell : utilisable dans St.DrawingArea comme dans un
// script gjs autonome (aperçu PNG).

import Pango from 'gi://Pango';
import PangoCairo from 'gi://PangoCairo';

import { chartScale, fmtPct } from './budget.js';

const USED = [0x35 / 255, 0x84 / 255, 0xe4 / 255]; // bleu GNOME
const OVER = [0xe6 / 255, 0x61 / 255, 0x00 / 255]; // orange GNOME (dépassement)

const COL_WIDTH = 24;
const RADIUS = 4;
const GAP = 2; // espace entre la part dans le budget et le dépassement
const PAD = { left: 50, right: 8, top: 38, bottom: 82 };

function topRounded(cr, x, y, w, h, r) {
    r = Math.min(r, w / 2, h);
    cr.newPath();
    cr.moveTo(x, y + h);
    cr.lineTo(x, y + r);
    cr.arc(x + r, y + r, r, Math.PI, 1.5 * Math.PI);
    cr.lineTo(x + w - r, y);
    cr.arc(x + w - r, y + r, r, 1.5 * Math.PI, 2 * Math.PI);
    cr.lineTo(x + w, y + h);
    cr.closePath();
}

function roundedRect(cr, x, y, w, h, r) {
    cr.newPath();
    cr.arc(x + w - r, y + r, r, -Math.PI / 2, 0);
    cr.arc(x + w - r, y + h - r, r, 0, Math.PI / 2);
    cr.arc(x + r, y + h - r, r, Math.PI / 2, Math.PI);
    cr.arc(x + r, y + r, r, Math.PI, 1.5 * Math.PI);
    cr.closePath();
}

/**
 * @param cr      contexte Cairo
 * @param width   largeur logique
 * @param height  hauteur logique
 * @param chart   résultat de weekChart() : { days, gaps }
 * @param opts    { fg: [r,g,b] 0–1, fontFamily, fontPx, resetTime: 'HH:MM', t: strings(lang) }
 */
export function drawWeekChart(cr, width, height, { days, gaps }, opts) {
    const { fg, fontFamily, resetTime, t } = opts;
    const num = x => fmtPct(x, t.lang);
    const base = opts.fontPx ?? 14;
    const ink = a => cr.setSourceRGBA(fg[0], fg[1], fg[2], a);

    const text = (str, x, y, { size = 0.8, bold = false, alpha = 1, align = 'center', valign = 'top' } = {}) => {
        const layout = PangoCairo.create_layout(cr);
        const fd = Pango.FontDescription.from_string(fontFamily);
        fd.set_absolute_size(base * size * Pango.SCALE);
        fd.set_weight(bold ? Pango.Weight.BOLD : Pango.Weight.NORMAL);
        layout.set_font_description(fd);
        layout.set_text(str, -1);
        const [, ext] = layout.get_pixel_extents();
        let tx = x;
        if (align === 'center')
            tx = x - ext.width / 2;
        else if (align === 'right')
            tx = x - ext.width;
        let ty = y;
        if (valign === 'bottom')
            ty = y - ext.height;
        else if (valign === 'middle')
            ty = y - ext.height / 2;
        ink(alpha);
        cr.moveTo(tx, ty);
        PangoCairo.show_layout(cr, layout);
        return ext.width;
    };
    const measure = (str, size, bold) => {
        const layout = PangoCairo.create_layout(cr);
        const fd = Pango.FontDescription.from_string(fontFamily);
        fd.set_absolute_size(base * size * Pango.SCALE);
        fd.set_weight(bold ? Pango.Weight.BOLD : Pango.Weight.NORMAL);
        layout.set_font_description(fd);
        layout.set_text(str, -1);
        return layout.get_pixel_extents()[1].width;
    };

    const plotLeft = PAD.left;
    const plotRight = width - PAD.right;
    const plotTop = PAD.top;
    const baseline = height - PAD.bottom;
    const slot = (plotRight - plotLeft) / days.length;
    const cx = i => plotLeft + slot * (i + 0.5);

    const values = days.flatMap(d => [d.budget ?? 0, d.used ?? 0]);
    const { max, step } = chartScale(Math.max(0, ...values));
    const yOf = v => baseline - (v / max) * (baseline - plotTop);

    // Fond discret derrière la colonne du jour.
    days.forEach((d, i) => {
        if (d.kind !== 'today')
            return;
        ink(0.05);
        roundedRect(cr, plotLeft + slot * i + 2, plotTop - 30, slot - 4, baseline - plotTop + 70, 8);
        cr.fill();
    });

    // Grille horizontale + graduations.
    cr.setLineWidth(1);
    for (let v = 0; v <= max + 1e-9; v += step) {
        const y = Math.round(yOf(v)) + 0.5;
        ink(v === 0 ? 0.25 : 0.08);
        cr.moveTo(plotLeft, y);
        cr.lineTo(plotRight, y);
        cr.stroke();
        text(v === 0 ? '0' : t.pct(v), plotLeft - 8, y, { size: 0.8, alpha: 0.55, align: 'right', valign: 'middle' });
    }

    // Colonnes.
    days.forEach((d, i) => {
        const x = cx(i) - COL_WIDTH / 2;
        if (d.kind === 'future') {
            const top = yOf(d.budget);
            if (baseline - top >= 1) {
                cr.setLineWidth(1.5);
                cr.setDash([3, 3], 0);
                ink(0.4);
                topRounded(cr, x + 0.75, top + 0.75, COL_WIDTH - 1.5, baseline - top - 0.75, RADIUS);
                cr.stroke();
                cr.setDash([], 0);
            }
            text(num(d.budget), cx(i), top - 4, { size: 0.85, alpha: 0.55, valign: 'bottom' });
            return;
        }
        if (d.kind !== 'past' && d.kind !== 'today')
            return;

        const budgetTop = yOf(d.budget);
        const usedTop = yOf(d.used);
        // Budget du jour : piste grise.
        if (baseline - budgetTop >= 1) {
            ink(0.14);
            topRounded(cr, x, budgetTop, COL_WIDTH, baseline - budgetTop, RADIUS);
            cr.fill();
        }
        if (d.used <= d.budget) {
            if (baseline - usedTop >= 0.5) {
                cr.setSourceRGB(...USED);
                topRounded(cr, x, usedTop, COL_WIDTH, baseline - usedTop, RADIUS);
                cr.fill();
            }
        } else {
            // Part dans le budget (bord droit), puis dépassement empilé.
            if (baseline - budgetTop >= 0.5) {
                cr.setSourceRGB(...USED);
                cr.rectangle(x, budgetTop, COL_WIDTH, baseline - budgetTop);
                cr.fill();
            }
            const overBottom = budgetTop - (d.budget > 0 ? GAP : 0);
            if (overBottom - usedTop >= 0.5) {
                cr.setSourceRGB(...OVER);
                topRounded(cr, x, usedTop, COL_WIDTH, overBottom - usedTop, RADIUS);
                cr.fill();
            }
        }
        const capTop = Math.min(budgetTop, usedTop);
        const today = d.kind === 'today';
        const used = num(d.used);
        const rest = ` / ${num(d.budget)}`;
        const wUsed = measure(used, 0.85, true);
        const wRest = measure(rest, 0.85, false);
        const left = cx(i) - (wUsed + wRest) / 2;
        text(used, left, capTop - 4, { size: 0.85, bold: true, alpha: today ? 1 : 0.9, align: 'left', valign: 'bottom' });
        text(rest, left + wUsed, capTop - 4, { size: 0.85, alpha: 0.6, align: 'left', valign: 'bottom' });
    });

    // Blocs des jours sans relevé.
    for (const g of gaps) {
        const x0 = plotLeft + slot * g.from + 6;
        const x1 = plotLeft + slot * (g.to + 1) - 6;
        const top = plotTop + (baseline - plotTop) * 0.2;
        ink(0.04);
        roundedRect(cr, x0, top, x1 - x0, baseline - top, 6);
        cr.fillPreserve();
        ink(0.22);
        cr.setLineWidth(1);
        cr.setDash([4, 4], 0);
        cr.stroke();
        cr.setDash([], 0);

        const mid = (x0 + x1) / 2;
        const midY = (top + baseline) / 2;
        const span = g.to - g.from + 1;
        const total = span > 1 ? t.chartTotal(t.pct(g.total)) : t.pct(g.total);
        const note = span > 1 ? t.chartUntrackedDays : t.chartUntracked;
        const room = x1 - x0 - 8;
        const size = measure(total, 1, true) <= room ? 1 : 0.8;
        text(total, mid, midY - 2, { size, bold: true, alpha: 0.85, valign: 'bottom' });
        if (measure(note, 0.8, false) <= room)
            text(note, mid, midY + 2, { size: 0.8, alpha: 0.55 });
    }

    // Jours sous l'axe.
    const last = days.length - 1;
    days.forEach((d, i) => {
        const today = d.kind === 'today';
        text(t.day(d.key), cx(i), baseline + 8, { size: 0.9, bold: today, alpha: today ? 1 : 0.75 });
        let sub = null;
        if (today)
            sub = t.chartToday;
        else if (i === 0 && d.weight < 1)
            sub = t.chartFrom(resetTime);
        else if (i === last && d.weight < 1)
            sub = t.chartUntil(resetTime);
        if (sub)
            text(sub, cx(i), baseline + 8 + base * 1.15, { size: 0.75, alpha: 0.5 });
    });

    // Légende.
    const ly = height - 14;
    let lx = plotLeft;
    const swatch = (draw, label) => {
        draw(lx, ly - 5);
        lx += 16;
        lx += text(label, lx, ly, { size: 0.85, alpha: 0.75, align: 'left', valign: 'middle' }) + 20;
    };
    swatch((x, y) => {
        cr.setSourceRGB(...USED);
        roundedRect(cr, x, y, 10, 10, 2);
        cr.fill();
    }, t.legendUsed);
    swatch((x, y) => {
        ink(0.14);
        roundedRect(cr, x, y, 10, 10, 2);
        cr.fill();
    }, t.legendBudget);
    swatch((x, y) => {
        cr.setSourceRGB(...OVER);
        roundedRect(cr, x, y, 10, 10, 2);
        cr.fill();
    }, t.legendOver);
    swatch((x, y) => {
        ink(0.45);
        cr.setLineWidth(1.2);
        cr.setDash([2, 2], 0);
        roundedRect(cr, x + 0.6, y + 0.6, 8.8, 8.8, 2);
        cr.stroke();
        cr.setDash([], 0);
    }, t.legendPlanned);
}
