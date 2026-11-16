/*
 * Practice playback renderer: a sample-exact port of the Android audio
 * thread (MainActivity.playPreview, AudioMixer, AudioLimiter, AudioCycle).
 *
 * Pure code with no DOM or Web Audio dependencies. It runs inside the
 * AudioWorklet (audio-worklet.js), in the ScriptProcessor fallback on the
 * main thread (audio.js), and under Node for the parity test
 * (scripts/web_audio_parity.mjs). Keep the synthesis maths here only.
 *
 * The renderer always works at 44,100 Hz in 1,024-frame chunks, exactly like
 * the Android AudioTrack loop: mixer gains are sampled once per chunk and
 * ramped linearly across it, notes join and leave the active list at chunk
 * starts, and each output sample is quantised to 16 bits as Android writes
 * it. When the output device runs at another rate, Player resamples.
 */

export const RATE = 44100;
export const CHUNK = 1024;

/** Recorded piano notes (Salamander Grand Piano) and their MIDI pitches. */
export const PIANO_SAMPLES = [['A0', 21], ['C1', 24], ['Fs1', 30], ['C2', 36], ['Fs2', 42],
  ['C3', 48], ['Fs3', 54], ['C4', 60], ['Fs4', 66], ['C5', 72], ['Fs5', 78],
  ['C6', 84], ['Fs6', 90], ['C7', 96], ['Fs7', 102], ['C8', 108]];

const INSTRUMENTS = ['choir', 'organ', 'sine', 'piano'];
const ORGAN_HARMONICS = [[2, 0.5], [3, 0.25], [4, 0.15]];
const CHOIR_HARMONICS = [[2, 0.22], [3, 0.12], [4, 0.06]];
const NO_HARMONICS = [];

/** Integer division of non-negative integers (Kotlin Long `/`). Exact below 2^53. */
const idiv = (a, b) => Math.floor(a / b);
const isInt = (v) => typeof v === 'number' && Number.isInteger(v);

/** Decodes mono 16-bit little-endian PCM. */
export function decodePcm(buffer) {
  const bytes = buffer instanceof ArrayBuffer ? new Uint8Array(buffer) : new Uint8Array(buffer.buffer, buffer.byteOffset, buffer.byteLength);
  if (bytes.length === 0 || bytes.length % 2 !== 0) throw new Error('ピアノ音源のデータが不正です。');
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const pcm = new Int16Array(bytes.length / 2);
  for (let i = 0; i < pcm.length; i++) pcm[i] = view.getInt16(2 * i, true);
  return pcm;
}

/* ---------------------------------------------------------------- AudioCycle */

/** Frame arithmetic shared by stream rendering and playback-head reporting. */
export class Cycle {
  constructor(frames, looping, offset = 0, loopStart = 0) {
    if (!(frames > 0 && offset >= 0 && offset <= frames && loopStart >= 0 && loopStart < frames)) {
      throw new Error('再生範囲が不正です。');
    }
    this.frames = frames; this.looping = looping; this.offset = offset; this.loopStart = loopStart;
  }
  phase(generated) {
    return generated < this.frames ? generated
      : this.loopStart + (generated - this.frames) % (this.frames - this.loopStart);
  }
  chunkSize(generated, capacity) {
    if (!this.looping && generated >= this.frames) return 0;
    return Math.min(capacity, this.frames - this.phase(generated));
  }
  playbackPosition(played) {
    return this.looping ? this.phase(this.offset + played) : Math.min(this.offset + played, this.frames);
  }
}

/* -------------------------------------------------------------- AudioLimiter */

/**
 * Keeps the summed voices inside the output range without clipping: a
 * look-ahead peak follower with hold and slow release, plus a soft knee.
 */
export class Limiter {
  constructor(rate, threshold = 1.0, ceiling = 1.25) {
    this.threshold = threshold; this.ceiling = ceiling;
    this.lookahead = Math.max(1, Math.trunc(rate * 0.002));
    this.delay = new Float64Array(this.lookahead);
    this.at = 0;
    this.hold = Math.trunc(rate * 0.035);
    this.release = Math.exp(-1.0 / (rate * 0.35));
    this.attack = Math.exp(-3.0 / this.lookahead);
    this.peak = 0.0; this.held = 0;
    this.gain = 1.0;
  }
  process(value) {
    const level = Math.abs(value);
    if (level >= this.peak) { this.peak = level; this.held = this.hold; }
    else if (this.held > 0) this.held--;
    else this.peak = Math.max(level, this.peak * this.release);
    const target = this.peak > this.threshold ? this.threshold / this.peak : 1.0;
    this.gain = target < this.gain ? target + (this.gain - target) * this.attack : target;
    const out = this.delay[this.at];
    this.delay[this.at] = value;
    this.at = (this.at + 1) % this.lookahead;
    return this.softClip(out * this.gain);
  }
  softClip(v) {
    const a = Math.abs(v);
    if (a <= this.threshold) return v;
    const room = this.ceiling - this.threshold;
    const shaped = this.threshold + room * Math.tanh((a - this.threshold) / room);
    return v < 0 ? -shaped : shaped;
  }
}

/* ---------------------------------------------------------------- AudioMixer */

const entriesOf = (m) => m instanceof Map ? [...m.entries()]
  : (m && typeof m === 'object' && !Array.isArray(m)) ? Object.entries(m) : [];
const listOf = (v) => Array.isArray(v) || v instanceof Set ? Array.from(v, String) : [];

/**
 * Validates a mixer map as AudioMixer.parse does and returns a plain,
 * structured-cloneable snapshot. Throws Error on invalid values.
 */
export function parseMixer(raw) {
  raw = raw || {};
  const gain = (v, fallback, what) => {
    const g = typeof v === 'number' ? v : fallback;
    if (!(Number.isFinite(g) && g >= 0 && g <= 1)) throw new Error(`${what}は0から1の範囲で指定してください。`);
    return g;
  };
  const volumes = {};
  for (const [k, v] of entriesOf(raw.volumes)) volumes[String(k)] = gain(v, 1.0, `${k} の音量`);
  const instruments = {};
  for (const [k, v] of entriesOf(raw.instruments)) {
    const inst = String(v);
    if (!INSTRUMENTS.includes(inst)) throw new Error(`楽器 ${inst} には対応していません。`);
    instruments[String(k)] = inst;
  }
  return {
    volumes, muted: listOf(raw.muted), solo: listOf(raw.solo),
    master: gain(raw.master, 0.8, '全体の音量'), instruments,
    metroVolume: gain(raw.metroVolume, 0.6, 'メトロノームの音量'),
  };
}

/** Lookup form of a parsed mixer, used by the renderer once per chunk. */
export function compileMixer(m) {
  const volumes = new Map(Object.entries(m.volumes || {}));
  const muted = new Set(m.muted || []);
  const solo = new Set(m.solo || []);
  const master = m.master ?? 0.8;
  const metroVolume = m.metroVolume ?? 0.6;
  return {
    instruments: new Map(Object.entries(m.instruments || {})),
    // As in the browser, explicit solos take precedence over mute.
    gain(part) {
      let g;
      if (part === '_metronome' || part === '_countin') g = metroVolume;
      else if (solo.size > 0 && !solo.has(part)) g = 0.0;
      else if (solo.size === 0 && muted.has(part)) g = 0.0;
      else g = volumes.has(part) ? volumes.get(part) : 1.0;
      return master * g;
    },
  };
}

/* ------------------------------------------------------------ play arguments */

/**
 * Validates the "play" argument map as MainActivity does. Returns plain data
 * (events with defaults resolved) that can be posted to the worklet.
 * `onMixer` receives the parsed mixer before the events are checked, matching
 * Android, which installs the mixer first.
 */
export function parsePlay(args, onMixer) {
  args = args || {};
  const fail = (msg) => { throw new Error(msg); };
  const raw = args.events == null ? [] : args.events;
  if (!Array.isArray(raw)) fail('音符データが不正です。');
  if (raw.length > 50000) fail('音符が多すぎます（50000個まで）。');
  const defaultPiano = args.piano === true;
  const intArg = (name) => {
    const v = args[name];
    if (v == null) return 0;
    if (!isInt(v)) fail(`${name} が整数ではありません。`);
    return v;
  };
  const lengthMs = intArg('lengthMs');
  const loop = args.loop === true;
  const offsetMs = intArg('offsetMs');
  const loopStartMs = intArg('loopStartMs');
  if (!(offsetMs >= 0 && offsetMs <= lengthMs)) fail('再生開始位置が範囲外です。');
  if (!(lengthMs >= 0 && lengthMs <= 1800000)) fail('再生は30分以内です。');
  if (!(loopStartMs >= 0 && (lengthMs === 0 || loopStartMs < lengthMs))) fail('反復の開始位置が範囲外です。');
  const mixer = parseMixer(args.mixer || {});
  if (onMixer) onMixer(mixer);
  const events = raw.map((e) => {
    if (!e || typeof e !== 'object') fail('音符データが不正です。');
    const { pitch, start, duration } = e;
    if (!isInt(pitch) || !isInt(start) || !isInt(duration)) fail('音符の高さ・開始・長さが整数ではありません。');
    const piano = typeof e.piano === 'boolean' ? e.piano : defaultPiano;
    const gain = typeof e.gain === 'number' ? e.gain : 1.0;
    const legato = typeof e.legato === 'boolean' ? e.legato : false;
    if (!(pitch >= 0 && pitch <= 127 && start >= 0 && duration > 0 && start + duration <= 1800000)) fail('音符の高さか時刻が範囲外です。');
    if (!(Number.isFinite(gain) && gain >= 0 && gain <= 1)) fail('音符の音量が範囲外です。');
    // Just-intonation offset; the written pitch stays as sent.
    const cents = typeof e.cents === 'number' ? e.cents : 0.0;
    if (!(Number.isFinite(cents) && cents >= -200 && cents <= 200)) fail('音程の補正（セント）が範囲外です。');
    return { pitch, start, duration, piano, gain, legato, part: typeof e.partId === 'string' ? e.partId : '', accent: e.accent === true, cents };
  });
  return { events, lengthMs, loop, offsetMs, loopStartMs, mixer };
}

/** Output length in 44.1 kHz frames, as playPreview computes it. */
export function totalFrames(events, lengthMs) {
  let end = 0;
  for (const e of events) end = Math.max(end, e.start + e.duration);
  return idiv(Math.max(lengthMs, end) * RATE, 1000);
}

/* ------------------------------------------------------------------ Renderer */

/**
 * The playPreview loop. `read` produces any number of frames; internally the
 * 1,024-frame chunk structure (gain ramps, note activation, loop resets) is
 * the same as Android's, so output is identical regardless of how the caller
 * slices it.
 */
export class Renderer {
  /**
   * @param play  {events, lengthMs, loop, offsetMs, loopStartMs} from parsePlay
   * @param samples [{pitch, data: Int16Array}] in PIANO_SAMPLES order, or null
   * @param mixer compiled mixer (compileMixer)
   */
  constructor(play, samples, mixer) {
    const rate = RATE;
    this.notes = play.events.map((event) => {
      let sample = null;
      if (samples) for (const s of samples) {
        if (sample === null || Math.abs(s.pitch - event.pitch) < Math.abs(sample.pitch - event.pitch)) sample = s;
      }
      // Tuning applies to both the oscillator and the piano sample speed.
      const tune = Math.pow(2.0, event.cents / 1200.0);
      return {
        first: idiv(event.start * rate, 1000),
        last: idiv((event.start + event.duration) * rate, 1000),
        frequency: 440.0 * Math.pow(2.0, (event.pitch - 69) / 12.0) * tune,
        sample: sample ? sample.data : null,
        sampleStep: sample === null ? 0.0 : 0.5 * Math.pow(2.0, (event.pitch - sample.pitch) / 12.0) * tune,
        gain: event.gain, legato: event.legato, part: event.part, piano: event.piano, accent: event.accent,
      };
    });
    this.notes.sort((a, b) => a.first - b.first); // stable, like sortedBy
    this.total = totalFrames(play.events, play.lengthMs);
    this.loop = play.loop;
    this.offsetFrames = idiv(play.offsetMs * rate, 1000);
    this.loopStartFrames = idiv(play.loopStartMs * rate, 1000);
    this.cycle = this.total === 0 ? null : new Cycle(this.total, this.loop, this.offsetFrames, this.loopStartFrames);
    this.position = this.offsetFrames;
    this.nextNote = 0;
    this.active = [];
    this.previousGains = new Map();
    this.limiter = new Limiter(rate);
    this.mixer = mixer;
    this.chunk = null;
  }

  /** Mixer changes take effect from the next chunk, as on Android. */
  setMixer(mixer) { this.mixer = mixer; }

  /** Fills out[at, at+n) and returns the frames written; fewer means the end. */
  read(out, at, n) {
    let written = 0;
    while (written < n) {
      const c = this.chunk;
      if (c === null || c.i >= c.count) {
        if (c !== null) { this.position += c.count; this.chunk = null; }
        if (!this.begin()) break;
        continue;
      }
      const m = Math.min(n - written, c.count - c.i);
      this.synth(c, out, at + written, m);
      written += m;
    }
    return written;
  }

  begin() {
    if (this.cycle === null || !(this.loop || this.position < this.total)) return false;
    const cycle = this.cycle.phase(this.position);
    if (cycle === 0 || (this.position >= this.total && cycle === this.loopStartFrames)) { this.nextNote = 0; this.active = []; }
    const count = this.cycle.chunkSize(this.position, CHUNK);
    if (count <= 0) return false;
    this.active = this.active.filter((n) => n.last > cycle);
    const notes = this.notes;
    while (this.nextNote < notes.length && notes[this.nextNote].first < cycle + count) {
      const note = notes[this.nextNote++];
      if (note.last > cycle) this.active.push(note);
    }
    const mixer = this.mixer;
    const active = this.active;
    const gains = active.map((n) => mixer.gain(n.part));
    const from = active.map((n, k) => this.previousGains.has(n.part) ? this.previousGains.get(n.part) : gains[k]);
    active.forEach((n, k) => this.previousGains.set(n.part, gains[k]));
    const instruments = active.map((n) => mixer.instruments.get(n.part) ?? (n.piano ? 'piano' : 'choir'));
    this.chunk = { cycle, count, i: 0, active, gains, from, instruments };
    return true;
  }

  synth(c, out, at, m) {
    const { cycle, count, active, gains, from, instruments } = c;
    const rate = RATE;
    const end = c.i + m;
    for (let i = c.i; i < end; i++) {
      const sample = cycle + i;
      let value = 0.0;
      for (let k = 0; k < active.length; k++) {
        const note = active[k];
        if (sample < note.first || sample >= note.last) continue;
        const age = sample - note.first;
        const liveGain = from[k] + (gains[k] - from[k]) * i / count;
        const envelope = Math.min(1.0, age / 220.0, (note.last - sample) / (note.legato ? 441.0 : 2205.0)) * note.gain * liveGain;
        if (envelope === 0.0) continue;
        const instrument = instruments[k];
        const pcm = instrument === 'piano' ? note.sample : null;
        if (note.part === '_metronome' || note.part === '_countin') {
          value += Math.sin(2 * Math.PI * (note.accent ? 1500 : 1000) * age / rate) * envelope;
          continue;
        }
        if (pcm === null) {
          const phase = 2 * Math.PI * note.frequency * age / rate;
          let wave = Math.sin(phase);
          const harmonics = instrument === 'organ' ? ORGAN_HARMONICS
            : instrument === 'choir' ? CHOIR_HARMONICS : NO_HARMONICS;
          for (let h = 0; h < harmonics.length; h++) {
            const harmonic = harmonics[h][0];
            if (note.frequency * harmonic < 22050) wave += Math.sin(phase * harmonic) * harmonics[h][1];
          }
          value += wave * envelope / (instrument === 'organ' ? 1.9 : 1.4);
        } else {
          const pos = age * note.sampleStep;
          const index = Math.trunc(pos);
          if (index + 1 < pcm.length) {
            const fraction = pos - index;
            value += (pcm[index] * (1 - fraction) + pcm[index + 1] * fraction) / 32768.0 * envelope;
          }
        }
      }
      const fadeIn = Math.min(1.0, (this.position - this.offsetFrames + i) / 220.0);
      // 7000 per unit as before; above 2.6 units the limiter turns the
      // level down smoothly instead of clipping (heard as buzzing).
      const s = Math.trunc(this.limiter.process(value * fadeIn / 2.6) * 18200);
      out[at + i - c.i] = ((s << 16) >> 16) / 32768;
    }
    c.i = end;
  }
}

/* -------------------------------------------------------------------- Player */

/** Renderer read straight into the output when the device runs at 44.1 kHz. */
class DirectSource {
  constructor(renderer) { this.renderer = renderer; }
  read(out) {
    const n = this.renderer.read(out, 0, out.length);
    if (n < out.length) { out.fill(0, n); return true; }
    return false;
  }
}

/** Cubic (Catmull-Rom) resampling from 44.1 kHz to the device rate. */
class ResampledSource {
  constructor(renderer, outRate) {
    this.renderer = renderer;
    this.step = RATE / outRate;
    this.buf = new Float32Array(256);
    this.len = 0; this.pos = 0; this.ended = false;
    this.produced = 0;   // real source frames delivered by next()
    this.index = 0;      // source index of x1
    this.t = 0;
    this.x0 = 0; this.x1 = this.next(); this.x2 = this.next(); this.x3 = this.next();
  }
  next() {
    if (this.pos >= this.len) {
      if (this.ended) return 0;
      this.len = this.renderer.read(this.buf, 0, this.buf.length);
      this.pos = 0;
      if (this.len < this.buf.length) this.ended = true;
      if (this.len === 0) return 0;
    }
    this.produced++;
    return this.buf[this.pos++];
  }
  read(out) {
    for (let k = 0; k < out.length; k++) {
      if (this.ended && this.index >= this.produced) { out.fill(0, k); return true; }
      const { x0, x1, x2, x3, t } = this;
      const c1 = 0.5 * (x2 - x0);
      const c2 = x0 - 2.5 * x1 + 2 * x2 - 0.5 * x3;
      const c3 = 0.5 * (x3 - x0) + 1.5 * (x1 - x2);
      out[k] = ((c3 * t + c2) * t + c1) * t + x1;
      this.t += this.step;
      while (this.t >= 1) {
        this.t -= 1;
        this.x0 = this.x1; this.x1 = this.x2; this.x2 = this.x3; this.x3 = this.next();
        this.index++;
      }
    }
    return false;
  }
}

/**
 * Message-driven playback engine, hosted by the AudioWorklet or the
 * ScriptProcessor fallback. Messages: {type:'samples', samples},
 * {type:'mixer', mixer}, {type:'play', gen, play, mixer}, {type:'stop'}.
 * Posts {type:'started', gen, time}, {type:'ended', gen} and
 * {type:'error', gen, message}.
 */
export class Player {
  constructor(outRate, post) {
    this.outRate = outRate;
    this.post = post;
    this.samples = null;
    this.mixer = compileMixer(parseMixer({}));
    this.job = null;
  }

  handle(msg) {
    switch (msg && msg.type) {
      case 'samples': this.samples = msg.samples; break;
      case 'mixer':
        this.mixer = compileMixer(msg.mixer);
        if (this.job) this.job.renderer.setMixer(this.mixer);
        break;
      case 'play': {
        this.job = null;
        if (msg.mixer) this.mixer = compileMixer(msg.mixer);
        try {
          const renderer = new Renderer(msg.play, this.samples, this.mixer);
          const source = this.outRate === RATE ? new DirectSource(renderer) : new ResampledSource(renderer, this.outRate);
          this.job = { gen: msg.gen, renderer, source, started: false };
        } catch (e) {
          this.post({ type: 'error', gen: msg.gen, message: (e && e.message) || String(e) });
        }
        break;
      }
      case 'stop': this.job = null; break;
    }
  }

  /** Fills one output block; `time` is the context time of out[0]. */
  process(out, time) {
    const job = this.job;
    if (!job) { out.fill(0); return; }
    try {
      if (!job.started) { job.started = true; this.post({ type: 'started', gen: job.gen, time }); }
      if (job.source.read(out)) { this.job = null; this.post({ type: 'ended', gen: job.gen }); }
    } catch (e) {
      out.fill(0);
      this.job = null;
      this.post({ type: 'error', gen: job.gen, message: (e && e.message) || String(e) });
    }
  }
}
