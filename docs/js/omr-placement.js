/*
 * Snaps recognised tokens onto the page image. Port of the 音鳥 Android
 * app's SymbolPlacement.kt.
 *
 * - Staff lines are measured at the start of the staff and at every barline
 *   (heights of the five lines there), so a tilted or slightly bent staff is
 *   followed bar by bar; between two barlines the lines are interpolated.
 * - Barlines snap to the nearest full-height vertical line.
 * - A note's height comes from its pitch, the clef and the local lines; its
 *   x snaps to the notehead found at that height (filled or hollow).
 *
 * mask is 1 for ink (omr-image.js inkMask). Tokens: {rhythm, pitch, x|null}
 * with x in page pixels. A place (TokenPlace) is
 * {x, y|null, confidence, snapped, lines|null}; placeToList gives the stored form.
 */
const BARLINES = new Set(['barline', 'doublebarline', 'bolddoublebarline', 'repeatStart', 'repeatEnd', 'repeatEndStart']);

const r1 = (v) => Math.round(v * 10) / 10;

/** TokenPlace.toList: [x, y|null, confidence, snapped, ...five line heights]. */
export function placeToList(p) {
  if (p == null) return null;
  const out = [r1(p.x), p.y == null ? null : r1(p.y), Math.round(p.confidence * 100) / 100, p.snapped];
  if (p.lines) for (const v of p.lines) out.push(r1(v));
  return out;
}

const tokenPlace = (x, y, confidence, snapped, lines = null) => ({ x, y, confidence, snapped, lines });

/** SymbolPlacement.place: one place (or null) per token. */
export function place(mask, width, height, lines, left, right, tokens) {
  if (lines.length !== 5 || tokens.length === 0) return tokens.map(() => null);
  const model = new LineModel(mask, width, height, lines, left, right);
  // 1. Staff lines at the start and at each barline (attention x first).
  // Measuring starts near the middle of the staff and walks outwards, so a
  // tilt accumulates gradually.
  const start = left + model.sp;
  const end = right - model.sp;
  const bars = [];
  tokens.forEach((t, i) => { if (BARLINES.has(t.rhythm) && t.x != null) bars.push(i); });
  model.measureAll([start, end, ...bars.map((i) => tokens[i].x)]);
  // 2. Barlines snap to the vertical line; re-measure the lines there.
  const out = new Array(tokens.length).fill(null);
  const snappedBars = [];
  for (const i of bars) {
    const x = tokens[i].x;
    let [bx, conf] = snapBarline(mask, width, height, model.at(x), x, model.sp, left, right);
    // The decoder places the final barline well before the staff end; the
    // staff's right edge is where it must be.
    if (bx == null && i === bars[bars.length - 1]) {
      const [ex, econf] = snapBarline(mask, width, height, model.at(right), right - 1.0, model.sp, left, right);
      if (ex != null && Math.abs(ex - right) <= 1.5 * model.sp) { bx = ex; conf = econf; }
    }
    snappedBars.push(bx ?? x);
    out[i] = tokenPlace(bx ?? x, null, conf, bx != null);
  }
  model.reset();
  model.measureAll([start, end, ...snappedBars]);
  for (const i of bars) out[i] = { ...out[i], lines: model.at(out[i].x) };
  // 3. Notes (pitch + clef -> height), rests, and the staff start.
  let bottomLine = diatonic('E4');
  let startGiven = false;
  // Token order says which bar a note is in: search between its barlines.
  tokens.forEach((t, i) => {
    let before = left, after = right;
    for (const b of bars) { if (b < i) before = out[b].x; else if (b > i) { after = out[b].x; break; } }
    if (t.rhythm.startsWith('clef_')) {
      const bottom = clefBottom(t.rhythm);
      if (bottom != null) bottomLine = bottom;
      // The first clef stands for the start of the staff (its left edge).
      if (!startGiven) { out[i] = tokenPlace(left, null, 1.0, true, model.at(start)); startGiven = true; }
    } else if (t.rhythm.startsWith('note_') && t.x != null) {
      const d = diatonic(t.pitch);
      out[i] = d == null ? tokenPlace(t.x, null, 0, false)
        : snapNote(mask, width, height, model, t.x, d - bottomLine, hollow(t.rhythm), t.rhythm.includes('G'), before, after);
    } else if (t.rhythm.startsWith('rest_') && t.x != null) {
      out[i] = tokenPlace(t.x, null, 0, false);
    }
  });
  return out;
}

/** Staff lines measured at several x, interpolated in straight lines between them. */
class LineModel {
  constructor(mask, width, height, base, left, right) {
    Object.assign(this, { mask, width, height, base, left, right });
    this.sp = (base[4] - base[0]) / 4;
    this.points = [];  // [x, lines], sorted by x (Kotlin sortedMapOf)
  }

  reset() { this.points = []; }

  at(x) {
    const p = this.points;
    if (p.length === 0) return this.base;
    let lower = null, upper = null;
    for (const e of p) { if (e[0] < x + 1e-9) lower = e; }          // headMap(x + 1e-9).lastKey
    for (const e of p) { if (e[0] >= x) { upper = e; break; } }      // tailMap(x).firstKey
    if (lower == null) return upper[1];
    if (upper == null || upper[0] === lower[0]) return lower[1];
    const t = (x - lower[0]) / (upper[0] - lower[0]);
    const a = lower[1], b = upper[1];
    return a.map((v, k) => v + t * (b[k] - v));
  }

  /** Nearest measured x (first in x order on ties), or null. */
  nearest(x) {
    let best = null, bestD = Infinity;
    for (const [k] of this.points) { const d = Math.abs(k - x); if (d < bestD) { bestD = d; best = k; } }
    return best;
  }

  /** Measure at xs, each guessed from the nearest measured point (tilt allowance grows with distance). */
  measureAll(xs) {
    const pending = xs.filter((x) => x >= this.left && x <= this.right);
    while (pending.length > 0) {
      let next = 0, bestD = Infinity;
      pending.forEach((x, i) => {
        const d = this.points.length === 0 ? Math.abs(x - (this.left + this.right) / 2) : Math.abs(this.nearest(x) - x);
        if (d < bestD) { bestD = d; next = i; }
      });
      const [x] = pending.splice(next, 1);
      this.measure(x);
    }
  }

  measure(x) {
    const nearest = this.nearest(x);
    const guess = nearest == null ? this.base : this.points.find((e) => e[0] === nearest)[1];
    const range = nearest == null ? 2.0 * this.sp : Math.min(2.5 * this.sp, 0.4 * this.sp + 0.07 * Math.abs(x - nearest));
    const fitted = this.fit(x, guess, range);
    if (fitted == null) return;
    const existing = this.points.findIndex((e) => e[0] === x);
    if (existing >= 0) { this.points[existing][1] = fitted; return; }
    let at = this.points.findIndex((e) => e[0] > x);
    if (at < 0) at = this.points.length;
    this.points.splice(at, 0, [x, fitted]);
  }

  /** Best vertical shift of the five lines in a narrow window, then each line refined. */
  fit(x, guess, range) {
    const { mask, width, height, sp } = this;
    const half = Math.max(3, Math.round(1.5 * sp));
    const x0 = Math.max(Math.max(0, this.left), Math.round(x) - half);
    const x1 = Math.min(Math.min(width, this.right), Math.round(x) + half);
    if (x1 - x0 < 3) return null;
    const yLo = Math.max(0, Math.trunc(guess[0] - range - sp));
    const yHi = Math.min(height - 1, Math.trunc(guess[4] + range + sp) + 1);
    if (yHi <= yLo) return null;
    const ink = new Float64Array(yHi - yLo + 1);
    for (let y = yLo; y <= yHi; y++) {
      let c = 0;
      for (let xx = x0; xx < x1; xx++) if (mask[y * width + xx] !== 0) c++;
      ink[y - yLo] = c / (x1 - x0);
    }
    const rowInk = (y) => (y < yLo || y > yHi ? 0 : ink[y - yLo]);
    const near = (y) => { const r = Math.round(y); return Math.max(rowInk(r - 1), Math.max(rowInk(r), rowInk(r + 1))); };
    let bestD = 0, best = -1;
    const r = Math.round(range);
    for (let d = -r; d <= r; d++) {
      let s = 0;
      for (const g of guess) s += near(g + d);
      s -= 0.002 * Math.abs(d);
      if (s > best) { best = s; bestD = d; }
    }
    if (best / 5 < 0.4) return null;  // no staff lines here (text, a gap)
    return guess.map((g) => {
      const c = g + bestD;
      const lo = Math.round(c - 0.3 * sp), hi = Math.round(c + 0.3 * sp);
      let peak = -Infinity;
      for (let y = lo; y <= hi; y++) peak = Math.max(peak, rowInk(y));
      let sw = 0, sy = 0;
      for (let y = lo; y <= hi; y++) { const v = rowInk(y); if (v >= 0.6 * peak) { sw += v; sy += v * y; } }
      return sw > 0 ? sy / sw : c;
    });
  }
}

/** Nearest full-height vertical line to x: [x or null, confidence]. */
function snapBarline(mask, width, height, lines, x, sp, left, right) {
  const top = Math.max(0, Math.round(lines[0])), bottom = Math.min(height - 1, Math.round(lines[4]));
  if (bottom <= top) return [null, 0];
  const c0 = Math.max(Math.max(0, left - 1), Math.trunc(x - 2.5 * sp));
  const c1 = Math.min(Math.min(width - 1, right + 1), Math.trunc(x + 3.5 * sp));
  const fill = new Float64Array(Math.max(0, c1 - c0 + 1));
  for (let k = 0; k < fill.length; k++) {
    const c = c0 + k;
    let n = 0;
    for (let y = top; y <= bottom; y++) {
      // Tolerate a pixel of skew: ink in this or a neighbouring column.
      const o = y * width + c;
      if (mask[o] !== 0 || (c > 0 && mask[o - 1] !== 0) || (c + 1 < width && mask[o + 1] !== 0)) n++;
    }
    fill[k] = n / (bottom - top + 1);
  }
  const runs = [];
  let k = 0;
  while (k < fill.length) {
    if (fill[k] < 0.92) { k++; continue; }
    const s = k;
    while (k < fill.length && fill[k] >= 0.92) k++;
    if (k - s <= 1.2 * sp + 2) runs.push([s, k - 1]);
  }
  if (runs.length === 0) return [null, 0];
  const centers = runs.map(([s, e]) => c0 + (s + e) / 2);
  let bi = 0;
  for (let i = 1; i < centers.length; i++) if (Math.abs(centers[i] - x) < Math.abs(centers[bi] - x)) bi = i;
  const best = centers[bi];
  let peak = 0;
  for (let i = runs[bi][0]; i <= runs[bi][1]; i++) peak = Math.max(peak, fill[i]);
  const strong = peak >= 0.97;
  const conf = centers.some((c) => Math.abs(c - best) > 0.8 * sp) ? 0.6  // several lines within reach
    : strong ? 1.0 : 0.8;
  return [best, conf];
}

function hollow(rhythm) {
  const code = rhythm.replace(/^note_/, '').replace(/G/g, '').replace(/\.+$/, '');
  return code === '1' || code === '2' || code === '0';
}

function snapNote(mask, width, height, model, attention, step, isHollow, grace, before, after) {
  const sp0 = model.sp;
  // Keep the search inside the bar; an estimate outside it is moved in.
  const lo = before + 0.4 * sp0, hi = after - 0.4 * sp0;
  const x = hi <= lo ? attention : Math.min(Math.max(attention, lo), hi);
  const lines = model.at(x);
  const sp = (lines[4] - lines[0]) / 4;
  const y = lines[4] - step * sp / 2;
  const scale = grace ? 0.7 : 1.0;
  const reach = x !== attention ? 4.0 : 2.0;
  let from = Math.trunc(x - reach * sp), to = Math.trunc(x + reach * sp);
  if (hi > lo) { from = Math.max(from, Math.trunc(lo)); to = Math.min(to, Math.trunc(hi)); }
  from = Math.max(0, from); to = Math.min(width - 1, to);
  let bestX = x, bestY = y, peak = -1;
  const profile = [];
  for (let cx = from; cx <= to; cx++) {
    let colBest = -1, colY = y;
    for (const dy of [0.0, -0.15 * sp, 0.15 * sp]) {
      const s = headScore(mask, width, height, cx, y + dy, sp * scale, isHollow);
      if (s > colBest) { colBest = s; colY = y + dy; }
    }
    profile.push(colBest);
    if (colBest > peak) { peak = colBest; bestX = cx; bestY = colY; }
  }
  if (peak < 0) return tokenPlace(x, y, 0, false);
  const [low, high] = isHollow ? [0.3, 0.65] : [0.4, 0.85];
  let conf = Math.min(Math.max((peak - low) / (high - low), 0), 1);
  // A beam or a long line at this height scores everywhere: not a head.
  const typical = [...profile].sort((a, b) => a - b)[profile.length >> 1];
  if (typical > 0.7 * peak) conf *= 0.5;
  return conf >= 0.5 ? tokenPlace(bestX, bestY, conf, true) : tokenPlace(x, y, conf, false);
}

/**
 * Ink inside a notehead-sized ellipse (filled) or in its rim (hollow), the
 * weaker of the left and right halves: a head is inked on both sides, while
 * a stem, barline or accidental beside it fills only one.
 */
function headScore(mask, width, height, cx, cy, sp, isHollow) {
  const rx = 0.6 * sp, ry = 0.48 * sp;
  const ink = [0, 0, 0, 0], total = [0, 0, 0, 0];  // [core left, core right, rim left, rim right]
  const yEnd = Math.trunc(cy + ry) + 1, xEnd = Math.trunc(cx + rx) + 1;
  for (let yy = Math.trunc(cy - ry); yy <= yEnd; yy++) {
    if (yy < 0 || yy >= height) continue;
    for (let xx = Math.trunc(cx - rx); xx <= xEnd; xx++) {
      if (xx < 0 || xx >= width) continue;
      const dx = (xx - cx) / rx, dy = (yy - cy) / ry;
      if (dx * dx + dy * dy > 1.0) continue;
      const core = (dx / 0.75) * (dx / 0.75) + (dy / 0.72) * (dy / 0.72) <= 1.0;
      const k = (core ? 0 : 2) + (dx < 0 ? 0 : 1);
      total[k]++;
      if (mask[yy * width + xx] !== 0) ink[k]++;
    }
  }
  if (total.some((t) => t === 0)) return 0;
  const f = ink.map((v, i) => v / total[i]);
  return isHollow ? Math.min(f[2], f[3]) : Math.min(f[0], f[1]);
}

const LETTERS = 'CDEFGAB';

/** Diatonic step number of "C5" etc. */
export function diatonic(pitch) {
  const m = /^([A-G])(\d)$/.exec(pitch);
  return m ? Number(m[2]) * 7 + LETTERS.indexOf(m[1]) : null;
}

/** Diatonic step of the bottom staff line for a clef token (clef_G2, clef_F4, clef_C3, ...). */
export function clefBottom(rhythm) {
  const m = /^clef_([GFC])(\d)/.exec(rhythm);
  if (!m) return null;
  const clefPitch = m[1] === 'G' ? diatonic('G4') : m[1] === 'F' ? diatonic('F3') : diatonic('C4');
  return clefPitch - 2 * (Number(m[2]) - 1);
}
