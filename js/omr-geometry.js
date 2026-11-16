/*
 * Five-line staff detection from the segmentation model's staff class,
 * ported from the 音鳥 Android app (StaffGeometry.kt). ES module.
 * Staff: {left, right, lines[5], spacing, stripSupport, inferredLine, profile: [[x, offset]]}
 */

function staffOffsetAt(staff, x) {
  const p = staff.profile;
  if (!p || p.length === 0) return 0;
  if (x <= p[0][0]) return p[0][1];
  if (x >= p[p.length - 1][0]) return p[p.length - 1][1];
  let i = 0;
  for (let k = 0; k < p.length; k++) if (p[k][0] <= x) i = k;
  const [x0, o0] = p[i], [x1, o1] = p[i + 1];
  return o0 + (o1 - o0) * (x - x0) / (x1 - x0);
}

function staffLinesAt(staff, x) { const o = staffOffsetAt(staff, x); return staff.lines.map((v) => v + o); }

function staffBent(staff) {
  const p = staff.profile;
  if (!p || p.length === 0) return false;
  let lo = Infinity, hi = -Infinity;
  for (const [, o] of p) { lo = Math.min(lo, o); hi = Math.max(hi, o); }
  return hi - lo >= 0.5 * staff.spacing;
}

/** Recover a clipped left edge only when two nearby staves agree. */
function restoreLeft(staff, neighbours) {
  const s = staff.spacing;
  const nearby = neighbours.filter((it) => {
    const gap = Math.max(it.lines[0] - staff.lines[4], staff.lines[0] - it.lines[4]);
    return gap >= 0 && gap <= 25 * s && Math.abs(it.right - staff.right) <= 5 * s;
  });
  for (let a = 0; a < nearby.length; a++) for (let b = a + 1; b < nearby.length; b++) {
    const f = nearby[a], g = nearby[b];
    if (Math.abs(f.left - g.left) <= 5 * s && Math.abs(f.right - g.right) <= 5 * s &&
        staff.left - Math.max(f.left, g.left) > 8 * s) {
      return { ...staff, left: Math.min(f.left, g.left) };
    }
  }
  return staff;
}

const STRIPS = 16;

function median(sorted) {
  const n = sorted.length;
  return n % 2 === 1 ? sorted[n >> 1] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2;
}

function predictFirstLine(cluster, strip) {
  const xs = cluster.map((c) => c.strip), ys = cluster.map((c) => c.lines[0]);
  const mx = xs.reduce((a, b) => a + b, 0) / xs.length, my = ys.reduce((a, b) => a + b, 0) / ys.length;
  let sxx = 0, sxy = 0;
  for (let i = 0; i < xs.length; i++) { sxx += (xs[i] - mx) ** 2; sxy += (xs[i] - mx) * (ys[i] - my); }
  if (sxx === 0) return ys[ys.length - 1];
  return my + (sxy / sxx) * (strip - mx);
}

function detectStaves(labels, width, height) {
  const peaksByStrip = Array.from({ length: STRIPS }, () => []);
  for (let strip = 0; strip < STRIPS; strip++) {
    const left = Math.trunc(strip * width / STRIPS), right = Math.trunc((strip + 1) * width / STRIPS);
    if (right - left < 24) continue;
    const rows = new Int32Array(height);
    for (let y = 0; y < height; y++) {
      const start = y * width;
      let n = 0;
      for (let x = left; x < right; x++) if (labels[start + x] === 4) n++;
      rows[y] = n;
    }
    const threshold = Math.max(3, Math.round((right - left) * 0.12));
    let y = 0;
    while (y < height) {
      if (rows[y] < threshold) { y++; continue; }
      let weighted = 0, total = 0;
      while (y < height && rows[y] >= threshold) { weighted += y * rows[y]; total += rows[y]; y++; }
      peaksByStrip[strip].push({ y: weighted / total, weight: total });
    }
  }
  const distances = new Int32Array(61);
  for (const peaks of peaksByStrip) for (let i = 1; i < peaks.length; i++) {
    const d = Math.round(peaks[i].y - peaks[i - 1].y);
    if (d >= 4 && d <= 60) distances[d]++;
  }
  let mode = 4;
  for (let d = 4; d <= 60; d++) if (distances[d] > distances[mode]) mode = d;
  if (distances[mode] < 4) return [];
  let weight = 0, total = 0;
  for (let d = Math.max(4, mode - 1); d <= Math.min(60, mode + 1); d++) { total += distances[d] * d; weight += distances[d]; }
  const spacing = total / weight;
  const candidates = [];
  for (let strip = 0; strip < STRIPS; strip++) {
    const peaks = peaksByStrip[strip];
    let i = 0;
    while (i < peaks.length) {
      let j = i;
      while (j + 1 < peaks.length && Math.abs(peaks[j + 1].y - peaks[j].y - spacing) <= spacing * 0.3) j++;
      let k = i;
      while (j - k + 1 >= 4) {
        const end = Math.min(j + 1, k + 5);
        candidates.push({ strip, lines: peaks.slice(k, end).map((p) => p.y) });
        k = end;
      }
      i = j + 1;
    }
  }
  if (candidates.length === 0) return [];

  function clusterAll(skew) {
    const level = candidates.map((c) => ({ strip: c.strip, lines: c.lines.map((v) => v - skew * c.strip) }));
    const clusters = [];
    level.forEach((candidate, index) => {
      let best = null, bestD = Infinity;
      for (const members of clusters) {
        if (members.some((m) => level[m].strip === candidate.strip)) continue;
        const cl = members.map((m) => level[m]);
        const near = cl.filter((c) => Math.abs(c.strip - candidate.strip) <= 2);
        let d = null;
        if (near.length > 0) {
          const distance = Math.min(...near.map((c) => Math.abs(c.lines[0] - candidate.lines[0])));
          if (distance <= 1.5 * spacing) d = distance;
        } else {
          const direct = Math.min(...cl.map((c) => Math.abs(c.lines[0] - candidate.lines[0])));
          const sloped = Math.abs(predictFirstLine(cl, candidate.strip) - candidate.lines[0]);
          if (direct <= 3 * spacing) d = Math.min(direct, sloped);
          else if (sloped <= 2 * spacing) d = sloped;
        }
        if (d !== null && d < bestD) { best = members; bestD = d; }
      }
      if (best === null) clusters.push([index]); else best.push(index);
    });
    return clusters.map((cl) => cl.map((i) => candidates[i]));
  }

  let clusters = clusterAll(0);
  const slopes = clusters.filter((cl) => new Set(cl.map((c) => c.strip)).size >= 4)
    .map((cl) => predictFirstLine(cl, 1) - predictFirstLine(cl, 0)).sort((a, b) => a - b);
  if (slopes.length > 0) {
    const skew = slopes[slopes.length >> 1];
    if (Math.abs(skew) * STRIPS >= 1.5 * spacing) clusters = clusterAll(skew);
  }
  const maxSupport = Math.max(...clusters.map((c) => c.length));
  const results = [];
  for (const cluster of clusters) {
    if (cluster.length < Math.max(2, maxSupport * 0.4)) continue;
    const full = cluster.filter((c) => c.lines.length === 5);
    const source = full.length > 0 ? full : cluster;
    const lines = [0, 1, 2, 3, 4].map((index) => median(source
      .map((c) => (index < c.lines.length ? c.lines[index] : c.lines[c.lines.length - 1] + spacing))
      .sort((a, b) => a - b)));
    const coarseLeft = Math.trunc(Math.min(...cluster.map((c) => c.strip)) * width / STRIPS);
    const coarseRight = Math.trunc((Math.max(...cluster.map((c) => c.strip)) + 1) * width / STRIPS);
    const profile = profileOf(labels, width, height, lines, spacing, coarseLeft, coarseRight);
    const shape = { left: 0, right: width, lines, spacing, stripSupport: cluster.length, inferredLine: full.length === 0, profile };
    const [left, right] = refineExtent(labels, width, height, shape, spacing, coarseLeft, coarseRight);
    results.push({ ...shape, left, right });
  }
  results.sort((a, b) => a.lines[0] - b.lines[0]);
  const out = [];
  for (const staff of results) {
    const last = out[out.length - 1];
    if (last && staff.lines[0] <= last.lines[4] + staff.spacing) {
      if (staff.stripSupport > last.stripSupport) out[out.length - 1] = staff;
    } else out.push(staff);
  }
  return out;
}

function profileOf(labels, width, height, lines, spacing, coarseLeft, coarseRight) {
  const strips = [];
  for (let s = 0; s < STRIPS; s++) {
    const l = Math.trunc(s * width / STRIPS), r = Math.trunc((s + 1) * width / STRIPS);
    if (r > coarseLeft && l < coarseRight && r - l >= 24) strips.push(s);
  }
  if (strips.length < 2) return [];
  function shiftIn(strip, expected, range) {
    const l = Math.trunc(strip * width / STRIPS), r = Math.trunc((strip + 1) * width / STRIPS);
    const y0 = Math.max(0, Math.trunc(lines[0] + expected - range - 2));
    const y1 = Math.min(height - 1, Math.trunc(lines[4] + expected + range + 2) + 1);
    const rows = new Float64Array(y1 - y0 + 1);
    for (let y = y0; y <= y1; y++) {
      let n = 0;
      for (let x = l; x < r; x++) if (labels[y * width + x] === 4) n++;
      rows[y - y0] = n / (r - l);
    }
    const at = (y) => (y < y0 || y > y1 ? 0 : rows[y - y0]);
    let best = -1, bestD = expected;
    for (let d = expected - range; d <= expected + range; d++) {
      let s = 0;
      for (const v of lines) { const y = Math.round(v + d); s += Math.max(at(y - 1), Math.max(at(y), at(y + 1))); }
      s -= 0.001 * Math.abs(d - expected);
      if (s > best) { best = s; bestD = d; }
    }
    return best / 5 >= 0.3 ? bestD : null;
  }
  const centre = (coarseLeft + coarseRight) / 2;
  let start = strips[0];
  for (const s of strips) if (Math.abs((s + 0.5) * width / STRIPS - centre) < Math.abs((start + 0.5) * width / STRIPS - centre)) start = s;
  const first = shiftIn(start, 0, Math.round(2 * spacing));
  if (first === null) return [];
  const step = Math.max(1, Math.round(0.6 * spacing));
  const shifts = new Map([[start, first]]);
  for (const direction of [-1, 1]) {
    let previous = first;
    const order = strips.filter((s) => (s - start) * direction > 0).sort((a, b) => Math.abs(a - start) - Math.abs(b - start));
    for (const strip of order) {
      const d = shiftIn(strip, previous, step);
      if (d === null) continue;
      shifts.set(strip, d);
      previous = d;
    }
  }
  return [...shifts.entries()].sort((a, b) => a[0] - b[0]).map(([strip, d]) => [(strip + 0.5) * width / STRIPS, d]);
}

function refineExtent(labels, width, height, shape, spacing, coarseLeft, coarseRight) {
  const lo = Math.max(0, coarseLeft - Math.trunc(2 * spacing));
  const hi = Math.min(width, coarseRight + Math.trunc(2 * spacing));
  const bent = staffBent(shape);
  function staffAt(x, lines) {
    const top = Math.max(0, Math.trunc(lines[0] - spacing));
    const bottom = Math.min(height, Math.trunc(lines[4] + spacing + 1));
    let count = 0;
    for (let y = top; y < bottom; y++) if (labels[y * width + x] === 4 && ++count >= 2) return true;
    return false;
  }
  const occupied = new Uint8Array(width);
  for (let x = lo; x < hi; x++) occupied[x] = staffAt(x, shape.lines) || (bent && staffAt(x, staffLinesAt(shape, x))) ? 1 : 0;
  let bestStart = -1, bestEnd = -1, currentStart = -1, lastInk = -1;
  const maxGap = Math.max(1, Math.round(spacing));
  for (let x = lo; x < hi; x++) {
    if (!occupied[x]) continue;
    if (currentStart < 0 || x - lastInk > maxGap + 1) {
      if (lastInk - currentStart > bestEnd - bestStart) { bestStart = currentStart; bestEnd = lastInk; }
      currentStart = x;
    }
    lastInk = x;
  }
  if (lastInk - currentStart > bestEnd - bestStart) { bestStart = currentStart; bestEnd = lastInk; }
  return bestStart >= 0 && bestEnd > bestStart ? [bestStart, bestEnd + 1] : [coarseLeft, coarseRight];
}

export { staffOffsetAt, staffLinesAt, staffBent, restoreLeft, detectStaves };
