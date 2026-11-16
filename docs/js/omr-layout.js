/*
 * Page layout from the ink mask: false staves, systems, piano braces.
 * Port of the 音鳥 Android app's PageLayout.kt (itself the image rules of
 * choir_omr/systems.py, mirrored by scripts/mobile_layout_reference.py).
 *
 * 1. A staff whose five lines are mostly not ink in the binarised page is a
 *    false staff (show-through, a cue staff over part of the width): dropped.
 * 2. A vertical ink line at the left end joins neighbouring staves into one
 *    system (system barline, bracket, brace); indented staves may join the
 *    system below; without any connection the gap heuristic is used.
 * 3. A brace in the left margin over two staves marks the piano pair, over
 *    the bottom three staves a three-staff piano.
 *
 * mask is 1 for ink (omr-image.js inkMask). Staff input (LayoutStaff):
 * {lines[5], left, right, profile: [[x, offset]]}.
 */
import { staffOffsetAt, staffBent } from './omr-geometry.js';
import { rint } from './omr-image.js';

export const MIN_LINE_INK = 0.5;
const SYSTEM_GAP_RATIO = 1.6;
const INDENT_RATIO = 0.25;
const INDENT_GAP_RATIO = 1.5;
const MIN_FILL = 0.85;

/**
 * LayoutStaff: offsetAt / slope of a staff whose spacing is taken from its
 * lines ((l4 - l0) / 4), 0 when the staff is straight (StaffGeometry.bent).
 */
export function layoutShape(staff) {
  const lines = staff.lines;
  const shape = { lines, profile: staff.profile || [], spacing: lines.length === 5 ? (lines[4] - lines[0]) / 4 : 1.0 };
  const bent = staffBent(shape);
  return {
    offsetAt: (x) => (bent ? staffOffsetAt(shape, x) : 0),
    slope: bent ? profileSlope(shape.profile) : 0,
  };
}

/** StaffGeometry.slope: least-squares dy/dx over the profile. */
function profileSlope(profile) {
  if (profile.length < 2) return 0;
  let mx = 0, my = 0;
  for (const [x, o] of profile) { mx += x; my += o; }
  mx /= profile.length; my /= profile.length;
  let sxx = 0, sxy = 0;
  for (const [x] of profile) sxx += (x - mx) * (x - mx);
  if (sxx === 0) return 0;
  for (const [x, o] of profile) sxy += (x - mx) * (o - my);
  return sxy / sxx;
}

function median(values) {
  const v = [...values].sort((a, b) => a - b);
  if (v.length === 0) return 0;
  const m = v.length >> 1;
  return v.length % 2 === 1 ? v[m] : (v[m - 1] + v[m]) / 2;
}

/**
 * PageLayout.analyze. Returns {systems: [{staves, pianoPair, pianoExtra}],
 * dropped, lineInk}; staff indices are ranks top to bottom.
 */
export function analyze(mask, width, height, staves) {
  const order = staves.map((_, i) => i).sort((a, b) => (staves[a].lines[0] ?? 0) - (staves[b].lines[0] ?? 0));
  const shapes = staves.map(layoutShape);
  const ink = staves.map((s, i) => (s.lines.length === 5
    ? lineInk(mask, width, height, s.lines, s.left, s.right, shapes[i].offsetAt) : 0));
  const keptOriginal = order.filter((i) => ink[i] >= MIN_LINE_INK);
  const rank = new Map(order.map((original, r) => [original, r]));
  // Systems are joined and braces found at the left end: use the lines there.
  const boxes = keptOriginal.map((i) => {
    const s = staves[i];
    const o = shapes[i].offsetAt(s.left);
    const l = s.lines.map((v) => v + o);
    const first = l[0], last = l[l.length - 1];
    return { index: i, y0: rint(first), y1: rint(last), x0: s.left, x1: s.right, spacing: (last - first) / 4,
      center: (first + last) / 2, slope: shapes[i].slope, get height() { return this.y1 - this.y0; } };
  });
  const systems = [];
  if (boxes.length > 0) {
    let breaks = [];
    if (boxes.length > 1) {
      const conn = [];
      for (let i = 0; i + 1 < boxes.length; i++) conn.push(connected(mask, width, height, boxes[i], boxes[i + 1]));
      breaks = conn.some((c) => c) ? joinIndented(boxes, conn.map((c) => !c)) : splitByGaps(boxes);
    }
    const groups = [[0]];
    breaks.forEach((brk, i) => { if (brk) groups.push([]); groups[groups.length - 1].push(i + 1); });
    for (const group of groups) {
      const members = group.map((g) => boxes[g]);
      const brace = findBrace(mask, width, height, members);
      const pair = brace ? (brace.length === 2 ? [brace[0], brace[1]] : [brace[1], brace[2]]) : null;
      const extra = brace && brace.length === 3 ? brace[0] : null;
      systems.push({ staves: members.map((m) => rank.get(m.index)), pianoPair: pair, pianoExtra: extra });
    }
  }
  const kept = new Set(keptOriginal);
  const dropped = order.filter((i) => !kept.has(i)).map((i) => rank.get(i));
  return { systems, dropped, lineInk: order.map((i) => ink[i]) };
}

/** LayoutSystem.toMap */
export function systemToMap(system) {
  const out = { staves: system.staves, has_brace: system.pianoPair != null };
  if (system.pianoPair != null) out.piano_pair = system.pianoPair;
  if (system.pianoExtra != null) out.piano_extra = system.pianoExtra;
  return out;
}

/** Skew-tolerant fraction of the staff's line pixels that are ink. */
export function lineInk(mask, width, height, lines, left, right, offsetAt = () => 0) {
  const x0 = Math.max(0, left), x1 = Math.min(width, right);
  if (x1 <= x0 || lines.length !== 5) return 0;
  const spacing = (lines[4] - lines[0]) / 4;
  const reach = Math.max(1, rint(spacing / 2));
  const strip = Math.max(16, rint(8 * spacing));
  let hits = 0, total = 0;
  for (let sx = x0; sx < x1; sx += strip) {
    const ex = Math.min(x1, sx + strip);
    const shift = offsetAt((sx + ex) / 2);
    let best = 0;
    for (let d = -reach; d <= reach; d++) {
      let count = 0;
      for (const y of lines) {
        const yi = rint(y + shift) + d;
        const a = Math.max(0, yi - 1), b = Math.min(height, yi + 2);
        if (b <= a) continue;
        for (let x = sx; x < ex; x++) {
          for (let row = a; row < b; row++) if (mask[row * width + x] !== 0) { count++; break; }
        }
      }
      best = Math.max(best, count);
    }
    hits += best; total += 5 * (ex - sx);
  }
  return total === 0 ? 0 : hits / total;
}

/** PC `staff_connections`, searched at both staves' left ends. */
function connected(mask, width, height, a, b) {
  const starts = [...new Set([Math.min(a.x0, b.x0), a.x0, b.x0])].sort((p, q) => p - q);
  for (const x0 of starts) if (connectedAt(mask, width, height, a, b, x0)) return true;
  return false;
}

function connectedAt(mask, width, height, a, b, x0) {
  const sp = a.spacing;
  const xa = Math.max(0, Math.trunc(x0 - 4 * sp));
  const xb = Math.min(width, Math.trunc(x0 + 3 * sp) + 1);
  const ya = Math.max(0, a.y1);
  const yb = Math.min(height, b.y0 + 1);
  if (yb - ya < 2 || xb - xa < 1) return false;
  const h = yb - ya, w = xb - xa;
  const region = new Uint8Array(h * w);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) region[y * w + x] = mask[(ya + y) * width + xa + x] !== 0 ? 1 : 0;
  for (let x = 0; x < w; x++) {
    let filled = 0;
    for (let y = 0; y < h; y++) filled += region[y * w + x];
    if (filled / h >= MIN_FILL) return true;
  }
  const kernel = Math.max(1, rint(0.15 * sp));
  const closed = closeVertical(region, w, h, kernel);
  return componentStats(closed, w, h).some((c) =>
    c.height >= MIN_FILL * h && c.top <= (1 - MIN_FILL) * h && c.top + c.height >= MIN_FILL * h);
}

/** OpenCV MORPH_CLOSE with a (k x 1) kernel: dilate, then erode (default borders). */
function closeVertical(src, w, h, k) {
  if (k <= 1) return src;
  const anchor = k >> 1;
  const dilated = new Uint8Array(src.length);
  for (let x = 0; x < w; x++) for (let y = 0; y < h; y++) {
    let v = 0;
    for (let i = 0; i < k; i++) { const yy = y + i - anchor; if (yy >= 0 && yy < h && src[yy * w + x] !== 0) { v = 1; break; } }
    dilated[y * w + x] = v;
  }
  const eroded = new Uint8Array(src.length);
  for (let x = 0; x < w; x++) for (let y = 0; y < h; y++) {
    let v = 1;
    for (let i = 0; i < k; i++) { const yy = y + i - anchor; if (yy >= 0 && yy < h && dilated[yy * w + x] === 0) { v = 0; break; } }
    eroded[y * w + x] = v;
  }
  return eroded;
}

/**
 * 8-connected components {top, height, left, width, area, leftTravel}.
 * leftTravel is how far the left edge moves over the middle 80% of the rows
 * (a brace curves, a bracket or barline is straight); shear (the staves'
 * dy/dx) is taken out first on a tilted page.
 */
function componentStats(src, w, h, shear = 0) {
  const seen = new Uint8Array(src.length);
  const out = [];
  const queue = new Int32Array(src.length);
  for (let start = 0; start < src.length; start++) {
    if (src[start] === 0 || seen[start]) continue;
    let head = 0, tail = 0;
    queue[tail++] = start; seen[start] = 1;
    let top = h, bottom = -1, left = w, right = -1, area = 0;
    while (head < tail) {
      const p = queue[head++];
      const y = (p / w) | 0, x = p - y * w;
      area++;
      if (y < top) top = y; if (y > bottom) bottom = y;
      if (x < left) left = x; if (x > right) right = x;
      for (let dy = -1; dy <= 1; dy++) for (let dx = -1; dx <= 1; dx++) {
        if (dx === 0 && dy === 0) continue;
        const ny = y + dy, nx = x + dx;
        if (ny < 0 || ny >= h || nx < 0 || nx >= w) continue;
        const q = ny * w + nx;
        if (!seen[q] && src[q] !== 0) { seen[q] = 1; queue[tail++] = q; }
      }
    }
    const rows = bottom - top + 1;
    const rowLeft = new Int32Array(rows).fill(2147483647);
    for (let k = 0; k < tail; k++) {
      const r = ((queue[k] / w) | 0) - top;
      rowLeft[r] = Math.min(rowLeft[r], queue[k] % w);
    }
    let lo = Infinity, hi = -Infinity;
    for (let r = Math.trunc(rows * 0.1); r < Math.trunc(rows * 0.9); r++) {
      const v = rowLeft[r] + shear * r;
      lo = Math.min(lo, v); hi = Math.max(hi, v);
    }
    out.push(component(top, rows, left, right - left + 1, area, hi >= lo ? hi - lo : 0));
  }
  return out;
}

function component(top, height, left, width, area, leftTravel = 0) {
  return { top, height, left, width, area, leftTravel, bottom: top + height, right: left + width };
}

function splitByGaps(boxes) {
  if (boxes.length < 2) return [];
  const rel = [];
  for (let i = 0; i < boxes.length - 1; i++) rel.push((boxes[i + 1].y0 - boxes[i].y1) / Math.max(1, boxes[i].height));
  const med = median(rel);
  return rel.map((r) => r > SYSTEM_GAP_RATIO * med && r > 2.0);
}

function joinIndented(boxes, breaks) {
  const n = boxes.length;
  if (n < 2 || !breaks.some((b) => b)) return breaks;
  const widest = Math.max(...boxes.map((b) => b.x1 - b.x0));
  const left = Math.min(...boxes.map((b) => b.x0));
  if (widest <= 0) return breaks;
  const indented = boxes.map((b) => (b.x0 - left) > INDENT_RATIO * widest);
  if (!indented.some((v) => v)) return breaks;
  const gaps = [];
  for (let i = 0; i < n - 1; i++) gaps.push(boxes[i + 1].y0 - boxes[i].y1);
  const inner = gaps.filter((_, i) => !breaks[i]);
  if (inner.length === 0) return breaks;
  const limit = INDENT_GAP_RATIO * median(inner);
  const out = [...breaks];
  let start = 0;
  for (let i = 0; i < n - 1; i++) {
    if (out[i]) {
      let groupIndented = true;
      for (let k = start; k <= i; k++) if (!indented[k]) { groupIndented = false; break; }
      if (groupIndented && gaps[i] <= limit) { out[i] = false; continue; }
      start = i + 1;
    }
  }
  return out;
}

/** Indices (within staves) covered by the best brace: 2, or the bottom 3. */
function findBrace(mask, width, height, staves) {
  if (staves.length < 2) return null;
  const starts = staves.map((s) => s.x0);
  const candidates = [...new Set([Math.min(...starts), Math.trunc(median(starts))])].sort((a, b) => a - b);
  let best = null;
  for (const sx0 of candidates) {
    const found = findBraceAt(mask, width, height, staves, sx0);
    if (!found) continue;
    if (best == null || found[0] > best[0]) best = found;
  }
  return best ? best[1] : null;
}

function findBraceAt(mask, width, height, staves, sx0) {
  const sp = median(staves.map((s) => s.spacing));
  const hs = median(staves.map((s) => s.height));
  const yTop = Math.min(...staves.map((s) => s.y0)), yBot = Math.max(...staves.map((s) => s.y1));
  const x1 = Math.trunc(sx0 - 0.2 * sp);
  const x0 = Math.max(0, Math.trunc(sx0 - 6 * sp));
  const y0 = Math.max(0, Math.trunc(yTop - hs));
  const y1 = Math.min(height, Math.trunc(yBot + hs));
  if (x1 - x0 < 2 || y1 - y0 < 2) return null;
  const w = x1 - x0, h = y1 - y0;
  const region = new Uint8Array(w * h);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) region[y * w + x] = mask[(y0 + y) * width + x0 + x] !== 0 ? 1 : 0;
  // A brace curves; the straight bar of a choir bracket (or a system
  // barline) is not a brace even when it spans two staves.
  const curved = componentStats(region, w, h, median(staves.map((s) => s.slope))).filter((c) =>
    c.width <= 3.0 * sp && c.width >= 0.5 * sp && c.area >= 0.3 * c.height && c.height >= hs && c.leftTravel >= 0.5 * sp);
  const coveredBy = (c) => staves.map((_, i) => i).filter((i) => y0 + c.top <= staves[i].center && staves[i].center <= y0 + c.bottom);
  // The thin middle of a small brace can vanish in the binarised page,
  // leaving an upper and a lower half over neighbouring staves.
  const halves = [];
  for (const a of curved) {
    const ca = coveredBy(a);
    if (ca.length !== 1) continue;
    for (const b of curved) {
      const cb = coveredBy(b);
      if (cb.length !== 1 || cb[0] !== ca[0] + 1) continue;
      const gap = b.top - a.bottom;
      if (gap < 0 || gap > staves[ca[0] + 1].y0 - staves[ca[0]].y1) continue;
      if (b.left >= a.right || a.left >= b.right) continue;
      const left = Math.min(a.left, b.left);
      halves.push(component(a.top, b.bottom - a.top, left, Math.max(a.right, b.right) - left, a.area + b.area));
    }
  }
  let best = null;
  for (const c of [...curved, ...halves]) {
    if (c.height < 1.5 * hs) continue;
    const top = y0 + c.top, bottom = y0 + c.top + c.height;
    const covered = staves.map((_, i) => i).filter((i) => top <= staves[i].center && staves[i].center <= bottom);
    if (covered.length < 2 || covered.length > 3 || covered[covered.length - 1] !== covered[0] + covered.length - 1) continue;
    if (covered.length === 3 && covered[2] !== staves.length - 1) continue;
    const span = staves[covered[covered.length - 1]].y1 - staves[covered[0]].y0;
    if (c.height > span + 1.5 * hs) continue;
    const score = c.width * c.height;
    if (best == null || score > best[0]) best = [score, covered];
  }
  return best;
}
