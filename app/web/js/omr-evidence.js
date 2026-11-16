/*
 * Image evidence for retrying inference, never a source of invented
 * measures. Port of the 音鳥 Android app's BarlineEvidence.kt.
 * Staves are StaffGeometry objects (omr-geometry.js); gray is the 1920-wide page.
 */

/** Barline x positions agreed by this staff and both neighbours; [] when not usable. */
export function corroboratedEnds(gray, width, height, staff, before, after) {
  if (before == null || after == null) return [];
  const spacing = staff.spacing;
  const first = (s) => s.lines[0], last = (s) => s.lines[s.lines.length - 1];
  if (last(before) >= first(staff) || first(after) <= last(staff) ||
      first(staff) - last(before) > 20 * spacing ||
      first(after) - last(staff) > 20 * spacing ||
      [before, after].some((it) => Math.abs(it.left - staff.left) > 5 * spacing || Math.abs(it.right - staff.right) > 5 * spacing)) {
    return [];
  }
  const preceding = verticals(gray, width, height, before);
  const following = verticals(gray, width, height, after);
  const tolerance = Math.max(3.0, spacing * 0.6);
  const agreed = verticals(gray, width, height, staff).filter((x) =>
    x > staff.left + 5 * spacing &&
    preceding.some((p) => Math.abs(p - x) <= tolerance) &&
    following.some((p) => Math.abs(p - x) <= tolerance));
  // Collapse the two strokes of a double/final barline.
  const ends = [];
  for (const x of agreed) {
    if (ends.length > 0 && x - ends[ends.length - 1] < 1.2 * spacing) ends[ends.length - 1] = x;
    else ends.push(x);
  }
  if (ends.length < 2 || ends.length > 32 || staff.right - ends[ends.length - 1] > 3 * spacing) return [];
  return ends;
}

function verticals(gray, width, height, staff) {
  const clamp = (v, lo, hi) => Math.min(Math.max(v, lo), hi);
  const top = clamp(Math.round(staff.lines[0] + staff.spacing * 0.65), 0, height - 1);
  const bottom = clamp(Math.round(staff.lines[staff.lines.length - 1] - staff.spacing * 0.65), top + 1, height);
  const peaks = [];
  for (let x = Math.max(1, staff.left); x < Math.min(width - 1, staff.right + 1); x++) {
    let dark = 0;
    for (let y = top; y < bottom; y++) {
      const o = y * width + x;
      if (gray[o - 1] < 130 || gray[o] < 130 || gray[o + 1] < 130) dark++;
    }
    if (dark / (bottom - top) >= 0.82) peaks.push(x);
  }
  const result = [];
  let start = 0;
  while (start < peaks.length) {
    let end = start;
    while (end + 1 < peaks.length && peaks[end + 1] - peaks[end] <= 3) end++;
    if (peaks[end] - peaks[start] <= Math.max(5.0, 1.5 * staff.spacing)) result.push((peaks[start] + peaks[end]) >> 1);
    start = end + 1;
  }
  return result;
}

/**
 * Count only populated measures, with the same lower-staff filter as Dart.
 * symbols: [rhythm, pitch, lift, position, articulation, slur, ...].
 */
export function measureCount(symbols) {
  let populated = false, count = 0;
  for (const s of symbols) {
    const rhythm = s[0];
    if (rhythm.endsWith('barline')) {
      if (populated) count++;
      populated = false;
    } else if (s[3] !== 'lower' && (rhythm.startsWith('note_') || rhythm.startsWith('rest_'))) {
      populated = true;
    }
  }
  return count + (populated ? 1 : 0);
}
