// Checks the browser playback renderer (web/js/audio-render.js) against the
// Android maths.
//
//   1. cd android && ./gradlew :app:testDebugUnitTest --tests jp.choiromr.mobile.PlaybackParityTest
//      (writes <tmp>/choir-audio-parity/*.pcm + *.json from the Kotlin loop)
//   2. node scripts/web_audio_parity.mjs
//
// Without step 1 only the standalone checks run.
import { readFileSync, existsSync, readdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';
import {
  RATE, CHUNK, PIANO_SAMPLES, Cycle, Limiter, Renderer, Player,
  compileMixer, decodePcm, parseMixer, parsePlay,
} from '../web/js/audio-render.js';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const pianoDir = existsSync(join(root, 'web/piano/C4.pcm')) ? join(root, 'web/piano') : join(root, 'android/app/src/main/assets/piano');
const samples = PIANO_SAMPLES.map(([name, pitch]) => ({ pitch, data: decodePcm(readFileSync(join(pianoDir, `${name}.pcm`))) }));
let failures = 0;
const check = (name, fn) => {
  try { fn(); console.log(`ok   ${name}`); } catch (e) { failures++; console.log(`FAIL ${name}: ${e.message}`); }
};

/** Renders with a per-chunk mixer schedule, reading in irregular slices. */
function render(play, schedule, frames, slices = [1, 7, 128, 300, 1024, 2048]) {
  const mixers = schedule.map((s) => ({ from: s.fromChunk, mixer: compileMixer(parseMixer(s.mixer)) }));
  const r = new Renderer(play, samples, mixers[0].mixer);
  let chunk = 0;
  const begin = r.begin.bind(r);
  r.begin = () => {
    r.setMixer(mixers.filter((m) => m.from <= chunk).at(-1).mixer);
    const ok = begin();
    if (ok) chunk++;
    return ok;
  };
  const out = new Float32Array(frames);
  let at = 0, k = 0;
  while (at < frames) {
    const n = r.read(out, at, Math.min(slices[k++ % slices.length], frames - at));
    if (n === 0) break;
    at += n;
  }
  return { out: out.subarray(0, at), renderer: r };
}

/* --------------------------------------------------- parity with Kotlin */

const dir = join(tmpdir(), 'choir-audio-parity');
const fixtures = existsSync(dir) ? readdirSync(dir).filter((f) => f.endsWith('.json')) : [];
if (fixtures.length === 0) console.log(`skip parity: no fixtures in ${dir} (run PlaybackParityTest first)`);
for (const file of fixtures) {
  const spec = JSON.parse(readFileSync(join(dir, file), 'utf8'));
  check(`parity ${spec.name}`, () => {
    const reference = decodePcm(readFileSync(join(dir, `${spec.name}.pcm`)));
    const play = parsePlay({ events: spec.events, lengthMs: spec.lengthMs, loop: spec.loop, offsetMs: spec.offsetMs,
      loopStartMs: spec.loopStartMs, mixer: spec.mixers[0].mixer });
    const { out } = render(play, spec.mixers, spec.loop ? spec.frames : spec.frames + 4096);
    assert.equal(out.length, reference.length, 'frame count');
    let maxDiff = 0, differing = 0, peak = 0;
    for (let i = 0; i < out.length; i++) {
      const d = Math.abs(Math.round(out[i] * 32768) - reference[i]);
      if (d > 0) differing++;
      maxDiff = Math.max(maxDiff, d);
      peak = Math.max(peak, Math.abs(reference[i]));
    }
    console.log(`     ${spec.name}: ${out.length} frames, peak ${peak}, max |diff| ${maxDiff} LSB, ${differing} samples differ`);
    assert.ok(maxDiff <= 1, `max diff ${maxDiff}`);
  });
}

/* ------------------------------------------------------ standalone checks */

const ev = (o) => ({ pitch: 69, start: 0, duration: 1000, ...o });
const flat = (play, frames, mixer = {}) => render(parsePlay(play), [{ fromChunk: 0, mixer }], frames).out;

check('envelope: 220-frame attack, 2205-frame release, 441 when legato', () => {
  const sine = { instruments: { s: 'sine' }, master: 1 };
  const a = flat({ events: [ev({ partId: 's' })] }, RATE, sine);
  const b = flat({ events: [ev({ partId: 's', legato: true })] }, RATE, sine);
  const peak = (x, from, to) => { let p = 0; for (let i = from; i < to; i++) p = Math.max(p, Math.abs(x[i])); return p; };
  const full = peak(a, 3000, 20000);
  assert.ok(peak(a, 0, 50) < full * 0.25, 'attack starts quiet');
  assert.ok(Math.abs(peak(a, 44100 - 2205 - 100, 44100 - 2105) - full) < full * 0.1, 'release starts 2205 frames before the end');
  assert.ok(peak(a, 44100 - 1102, 44100 - 1002) < full * 0.55 && peak(a, 44100 - 1102, 44100 - 1002) > full * 0.4, 'half way down');
  assert.ok(Math.abs(peak(b, 44100 - 600, 44100 - 500) - full) < full * 0.05, 'legato still full 500 frames before the end');
  assert.ok(peak(b, 44100 - 40, 44100) < full * 0.35, 'legato releases in 441 frames (output is 88 frames behind)');
});

check('limiter: quiet signal passes unchanged, only delayed', () => {
  const l = new Limiter(RATE);
  const delay = Math.trunc(RATE * 0.002);
  const input = Array.from({ length: 4000 }, (_, i) => Math.sin(2 * Math.PI * 220 * i / RATE) * 0.8);
  const out = input.map((v) => l.process(v));
  for (let i = 0; i < 4000 - delay; i++) assert.ok(Math.abs(out[i + delay] - input[i]) < 1e-12);
});

check('cycle: loop wraps to loopStart and the head follows the offset', () => {
  const c = new Cycle(1000, true, 600, 300);
  assert.equal(c.phase(999), 999); assert.equal(c.phase(1000), 300); assert.equal(c.phase(1700), 300);
  assert.equal(c.chunkSize(950, 1024), 50);
  assert.equal(c.playbackPosition(0), 600); assert.equal(c.playbackPosition(400), 300);
  assert.equal(new Cycle(1000, false, 600).playbackPosition(10000), 1000);
});

check('loop: second pass from loopStart repeats the first pass exactly', () => {
  // A quiet note so the limiter stays at unity; fade-in long finished.
  const play = { events: [ev({ start: 100, duration: 300, gain: 0.3 })], lengthMs: 500, loop: true, loopStartMs: 100 };
  const out = flat(play, Math.round(RATE * 1.4));
  const total = RATE / 2, loopStart = RATE / 10, period = total - loopStart;
  for (let i = total; i < total + period; i++) assert.equal(out[i + period], out[i], `frame ${i}`);
  for (let i = loopStart + 1000; i < total; i++) assert.equal(out[i + period], out[i], `frame ${i}`);
});

check('mixer: solo beats mute, mute silences, master and metronome', () => {
  const m = compileMixer(parseMixer({ volumes: { S: 0.5 }, muted: ['S', 'A'], solo: ['S'], master: 0.5, metroVolume: 0.2 }));
  assert.equal(m.gain('S'), 0.25); assert.equal(m.gain('A'), 0); assert.equal(m.gain('_metronome'), 0.1);
  const n = compileMixer(parseMixer({ muted: ['A'] }));
  assert.equal(n.gain('A'), 0); assert.equal(n.gain('T'), 0.8);
  assert.throws(() => parseMixer({ master: 1.5 })); assert.throws(() => parseMixer({ instruments: { S: 'violin' } }));
});

check('mixer: a live change ramps across one chunk', () => {
  const play = parsePlay({ events: [ev({ partId: 'S', duration: 2000 })], mixer: { instruments: { S: 'sine' } } });
  const { out } = render(play, [{ fromChunk: 0, mixer: { instruments: { S: 'sine' } } }, { fromChunk: 20, mixer: { instruments: { S: 'sine' }, muted: ['S'] } }], RATE);
  const peak = (from, to) => { let p = 0; for (let i = from; i < to; i++) p = Math.max(p, Math.abs(out[i])); return p; };
  assert.ok(peak(19 * CHUNK, 20 * CHUNK) > 0.1);
  assert.ok(peak(20 * CHUNK, 20 * CHUNK + 100) > 0.1, 'starts at the old gain');
  assert.equal(peak(21 * CHUNK + 100, 30 * CHUNK), 0, 'muted after the ramp');
});

check('cents: +100 cents equals one semitone up', () => {
  const sine = { instruments: { s: 'sine' } };
  const a = flat({ events: [ev({ partId: 's', pitch: 60, cents: 100 })] }, 20000, sine);
  const b = flat({ events: [ev({ partId: 's', pitch: 61 })] }, 20000, sine);
  for (let i = 0; i < 20000; i++) assert.ok(Math.abs(a[i] - b[i]) <= 2 / 32768);
  assert.throws(() => parsePlay({ events: [ev({ cents: 250 })] }));
});

check('validation mirrors MainActivity', () => {
  assert.throws(() => parsePlay({ lengthMs: 100, offsetMs: 200 }));
  assert.throws(() => parsePlay({ lengthMs: 1800001 }));
  assert.throws(() => parsePlay({ lengthMs: 100, loopStartMs: 100 }));
  assert.throws(() => parsePlay({ events: [ev({ pitch: 128 })] }));
  assert.throws(() => parsePlay({ events: [ev({ duration: 0 })] }));
  assert.throws(() => parsePlay({ events: [ev({ gain: 1.2 })] }));
  assert.throws(() => parsePlay({ events: [ev({ pitch: 60.5 })] }));
  const p = parsePlay({ piano: true, events: [ev({}), ev({ piano: false, partId: 'S', accent: 1 })] });
  assert.equal(p.events[0].piano, true); assert.equal(p.events[1].piano, false); assert.equal(p.events[1].accent, false);
  assert.equal(p.events[0].part, '');
});

check('player: 48 kHz output keeps duration and pitch', () => {
  const messages = [];
  const player = new Player(48000, (m) => messages.push(m));
  player.handle({ type: 'samples', samples });
  player.handle({ type: 'mixer', mixer: parseMixer({ instruments: { s: 'sine' } }) });
  player.handle({ type: 'play', gen: 3, play: parsePlay({ events: [ev({ partId: 's', pitch: 69 })] }) });
  const blocks = [];
  for (let i = 0; i < 400 && !messages.some((m) => m.type === 'ended'); i++) {
    const b = new Float32Array(128); player.process(b, i * 128 / 48000); blocks.push(b);
  }
  assert.deepEqual(messages[0], { type: 'started', gen: 3, time: 0 });
  const out = new Float32Array(blocks.length * 128); blocks.forEach((b, i) => out.set(b, i * 128));
  let last = 0; for (let i = 0; i < out.length; i++) if (out[i] !== 0) last = i;
  assert.ok(Math.abs(last - 48000) < 200, `last sample ${last}`);
  let crossings = 0; for (let i = 10000; i < 34000; i++) if (out[i - 1] < 0 && out[i] >= 0) crossings++;
  assert.ok(Math.abs(crossings - 220) <= 1, `${crossings} cycles in 0.5 s`);
});

check('piano: nearest recording, half speed for 22.05 kHz data', () => {
  const r = new Renderer(parsePlay({ piano: true, events: [ev({ pitch: 63 }), ev({ pitch: 64 }), ev({ pitch: 27 })] }), samples, compileMixer(parseMixer({})));
  const [a, b, c] = r.notes;
  assert.equal(a.sample, samples[7].data); assert.equal(b.sample, samples[8].data); // 63 -> C4 (tie keeps the first), 64 -> Fs4
  assert.equal(c.sample, samples[1].data); // 27: C1 and Fs1 tie, the first wins
  assert.ok(Math.abs(a.sampleStep - 0.5 * 2 ** (3 / 12)) < 1e-15);
});

console.log(failures ? `\n${failures} check(s) failed` : '\nall checks passed');
process.exit(failures ? 1 : 0);
