/*
 * Practice playback for the browser build: the score channel's play / stop /
 * playbackStatus / updateMixer, as MainActivity.kt answers them on Android.
 *
 * The synthesis itself lives in audio-render.js (a sample-exact port of
 * playPreview). It runs in an AudioWorklet (audio-worklet.js), or in a
 * ScriptProcessor on the main thread where worklets are unavailable (plain
 * http, old WebKit). This file owns the AudioContext, the generation counter,
 * the playback-head clock, piano sample loading and interruption handling.
 *
 * iOS Safari only starts audio from a user gesture, so a capture-phase
 * listener resumes the context on the first tap (and again whenever the
 * context is suspended); Flutter's play() arrives a few ms after that tap.
 */
import { RATE, PIANO_SAMPLES, Cycle, Player, decodePcm, parseMixer, parsePlay, totalFrames } from './audio-render.js';

const LOST_FOCUS = '他の音声が優先されたため一時停止しました。';
const ROUTE_CHANGED = '音声出力先が変わったため一時停止しました。';
const LEFT_SCREEN = '画面を離れたため一時停止しました。';
const NO_FOCUS = '音声出力の優先権を取得できません。画面を開いてから再試行してください。';
const NOT_UNLOCKED = '音声出力を開始できません。画面をタップしてから再試行してください。';
const IDLE_SUSPEND_MS = 30000;

const state = { generation: 0, playing: false, positionMs: 0, error: null, interruption: null };
let mixer = parseMixer({});
let context = null;
let engine = null;      // {ctx, ready: Promise, send, samplesSent}
let samples = null;     // Promise<[{pitch, data}]>
let job = null;         // the started playback: {gen, ctx, cycle, total, offsetFrames, loop, startTime}
let idleTimer = null;

const describe = (e) => (e && e.message) || String(e);
const idiv = (a, b) => Math.floor(a / b);

const isIOS = () => typeof navigator !== 'undefined' &&
  (/iPad|iPhone|iPod/.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1));

/** Plays through the silent switch while practising, as Android's media stream does. */
function setSession(type) {
  try { if (navigator.audioSession) navigator.audioSession.type = type; } catch (_) { /* unsupported */ }
}

/* ------------------------------------------------------------ AudioContext */

function ensureContext() {
  if (context && context.state !== 'closed') return context;
  const Ctor = globalThis.AudioContext || globalThis.webkitAudioContext;
  if (!Ctor) throw new Error('このブラウザは音声再生に対応していません。');
  // Render at Android's 44.1 kHz where the browser resamples well. iOS
  // WebKit has had glitches with a rate other than the hardware's, so there
  // the device rate is used and the Player resamples.
  const options = { latencyHint: 'interactive' };
  if (!isIOS()) options.sampleRate = RATE;
  let ctx;
  try { ctx = new Ctor(options); } catch (_) { ctx = new Ctor(); }
  ctx.onstatechange = () => onContextState(ctx);
  context = ctx;
  engine = null;
  return ctx;
}

function onContextState(ctx) {
  if (ctx !== context) return;
  if (ctx.state === 'running') { removeUnlock(); return; }
  installUnlock();
  // Suspended or interrupted (call, Siri, another app) while playing.
  if (job && job.ctx === ctx) interrupt(LOST_FOCUS);
}

async function ensureRunning(ctx) {
  if (ctx.state === 'running') return;
  const resumed = ctx.resume().catch(() => {});
  await Promise.race([resumed, new Promise((r) => setTimeout(r, 1500))]);
  if (ctx.state !== 'running') throw new Error(NOT_UNLOCKED);
}

function scheduleIdleSuspend() {
  clearTimeout(idleTimer);
  idleTimer = setTimeout(() => {
    if (!state.playing && context && context.state === 'running') context.suspend().catch(() => {});
  }, IDLE_SUSPEND_MS);
}

/* ---------------------------------------------------------- gesture unlock */

const UNLOCK_EVENTS = ['pointerdown', 'pointerup', 'touchend', 'mousedown', 'keydown'];
let unlockInstalled = false;

function unlock() {
  let ctx;
  try { ctx = ensureContext(); } catch (_) { removeUnlock(); return; }
  if (ctx.state !== 'running') {
    ctx.resume().catch(() => {});
    // Older iOS WebKit also wants a source started inside the gesture.
    try {
      const source = ctx.createBufferSource();
      source.buffer = ctx.createBuffer(1, 1, ctx.sampleRate);
      source.connect(ctx.destination);
      source.start(0);
    } catch (_) { /* ignore */ }
    if (!state.playing) scheduleIdleSuspend();
  }
  ensureEngine(ctx).catch(() => {}); // load the worklet before play() needs it
}

function installUnlock() {
  if (unlockInstalled || typeof window === 'undefined') return;
  unlockInstalled = true;
  for (const type of UNLOCK_EVENTS) window.addEventListener(type, unlock, { capture: true, passive: true });
}

function removeUnlock() {
  if (!unlockInstalled) return;
  unlockInstalled = false;
  for (const type of UNLOCK_EVENTS) window.removeEventListener(type, unlock, { capture: true });
}

/* ------------------------------------------------------------------ engine */

function ensureEngine(ctx) {
  if (engine && engine.ctx === ctx) return engine.ready;
  const e = { ctx, ready: null, send: null, samplesSent: false, node: null };
  engine = e;
  e.ready = (async () => {
    if (ctx.audioWorklet && typeof AudioWorkletNode === 'function') {
      try {
        await ctx.audioWorklet.addModule(new URL('./audio-worklet.js', import.meta.url));
        const node = new AudioWorkletNode(ctx, 'choir-playback',
          { numberOfInputs: 0, numberOfOutputs: 1, outputChannelCount: [1] });
        node.port.onmessage = (m) => onEngineMessage(m.data);
        node.onprocessorerror = () => onEngineMessage({ type: 'error', gen: state.generation, message: '音声処理が停止しました。' });
        node.connect(ctx.destination);
        e.node = node;
        e.send = (msg) => node.port.postMessage(msg);
        return e;
      } catch (err) {
        console.warn('AudioWorklet unavailable, using ScriptProcessor', err);
      }
    }
    // Main-thread fallback with the same Player.
    const player = new Player(ctx.sampleRate, (m) => queueMicrotask(() => onEngineMessage(m)));
    const node = ctx.createScriptProcessor(2048, 1, 1);
    node.onaudioprocess = (ev) => {
      const time = typeof ev.playbackTime === 'number' ? ev.playbackTime : ctx.currentTime + node.bufferSize / ctx.sampleRate;
      player.process(ev.outputBuffer.getChannelData(0), time);
    };
    node.connect(ctx.destination);
    e.node = node;
    e.send = (msg) => player.handle(msg);
    return e;
  })();
  e.ready.catch(() => { if (engine === e) engine = null; });
  return e.ready;
}

function send(msg) { if (engine && engine.send) engine.send(msg); }

function onEngineMessage(m) {
  if (!m || m.gen !== state.generation) return;
  if (m.type === 'started') {
    if (job && job.gen === m.gen) job.startTime = m.time;
  } else if (m.type === 'error') {
    state.error = m.message || '音声出力を開始できません。';
    finish();
  }
  // 'ended': the head clock below decides when the last sample was heard.
}

/* ------------------------------------------------------------ piano samples */

function loadSamples() {
  if (!samples) {
    samples = Promise.all(PIANO_SAMPLES.map(async ([name, pitch]) => {
      const response = await fetch(new URL(`piano/${name}.pcm`, document.baseURI));
      if (!response.ok) throw new Error(`piano/${name}.pcm (${response.status})`);
      return { pitch, data: decodePcm(await response.arrayBuffer()) };
    }));
    samples.catch(() => { samples = null; });
  }
  return samples;
}

/* ------------------------------------------------------------ playback head */

/** Context time of the sample now leaving the speaker. */
function outputTime(ctx) {
  const now = ctx.currentTime;
  try {
    const ts = ctx.getOutputTimestamp && ctx.getOutputTimestamp();
    if (ts && ts.contextTime > 0 && ts.performanceTime > 0) {
      const ahead = (performance.now() - ts.performanceTime) / 1000;
      const t = ts.contextTime + (ahead >= 0 && ahead < 0.5 ? ahead : 0);
      if (t > now - 1) return Math.min(t, now);
    }
  } catch (_) { /* fall back */ }
  return now - (ctx.outputLatency || 0) - (ctx.baseLatency || 0);
}

/** Updates positionMs from the output clock, and ends a finished playback. */
function refresh() {
  if (!state.playing || !job || job.gen !== state.generation || job.startTime == null) return;
  const played = Math.max(0, Math.floor((outputTime(job.ctx) - job.startTime) * RATE));
  if (!job.loop && played >= job.total - job.offsetFrames) {
    state.positionMs = idiv(job.total * 1000, RATE);
    finish();
    return;
  }
  state.positionMs = idiv(job.cycle.playbackPosition(played) * 1000, RATE);
}

function finish() {
  state.playing = false;
  job = null;
  setSession('auto');
  scheduleIdleSuspend();
}

/** AudioInterruptionGuard: playback never resumes by itself. */
function interrupt(reason) {
  if (!state.playing) return;
  refresh();
  state.generation++;
  state.interruption = reason;
  send({ type: 'stop' });
  finish();
}

if (typeof document !== 'undefined') {
  document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'hidden') interrupt(LEFT_SCREEN); });
  window.addEventListener('pagehide', () => interrupt(LEFT_SCREEN));
  try { navigator.mediaDevices?.addEventListener?.('devicechange', () => interrupt(ROUTE_CHANGED)); } catch (_) { /* ignore */ }
  installUnlock();
}

/* -------------------------------------------------------------- channel API */

/**
 * Starts playback; resolves once the samples are loaded and the renderer has
 * been handed the notes (Android replies at the same point). Rejects with
 * the validation or loading problem.
 */
export async function play(args) {
  // The mixer is installed before the events are checked, as on Android.
  const parsed = parsePlay(args, (m) => { mixer = m; send({ type: 'mixer', mixer }); });
  if (typeof document !== 'undefined' && document.visibilityState === 'hidden') throw new Error(NO_FOCUS);
  const gen = ++state.generation;
  send({ type: 'stop' });
  job = null;
  clearTimeout(idleTimer);
  state.interruption = null; state.positionMs = parsed.offsetMs; state.playing = true; state.error = null;
  let ctx;
  try {
    ctx = ensureContext();
    if (ctx.state !== 'running') ctx.resume().catch(() => {});
    const [pcm, e] = await Promise.all([loadSamples(), ensureEngine(ctx)]);
    if (!e.samplesSent) { e.send({ type: 'samples', samples: pcm }); e.samplesSent = true; }
  } catch (err) {
    if (gen === state.generation) { state.error = describe(err) || '音声出力を開始できません。'; finish(); }
    throw new Error(`音源を読み込めません: ${describe(err)}`);
  }
  if (gen !== state.generation) return; // superseded; Android also replies success
  try { await ensureRunning(ctx); } catch (err) {
    if (gen === state.generation) finish();
    throw err;
  }
  if (gen !== state.generation) return;
  state.positionMs = parsed.offsetMs;
  const total = totalFrames(parsed.events, parsed.lengthMs);
  if (total === 0) { finish(); return; }
  const offsetFrames = idiv(parsed.offsetMs * RATE, 1000);
  let cycle;
  try { cycle = new Cycle(total, parsed.loop, offsetFrames, idiv(parsed.loopStartMs * RATE, 1000)); } catch (err) {
    state.error = describe(err); finish(); return; // Android fails after replying
  }
  setSession('playback');
  job = { gen, ctx, cycle, total, offsetFrames, loop: parsed.loop, startTime: null };
  const { events, lengthMs, loop, offsetMs, loopStartMs } = parsed;
  send({ type: 'play', gen, play: { events, lengthMs, loop, offsetMs, loopStartMs }, mixer });
}

export function stop() {
  refresh();
  state.generation++;
  send({ type: 'stop' });
  if (state.playing) finish(); else job = null;
}

export function playbackStatus() {
  refresh();
  return { playing: state.playing, positionMs: state.positionMs, error: state.error, interruption: state.interruption };
}

/** Applies from the next 1,024-frame chunk (about 23 ms), as on Android. */
export function updateMixer(args) {
  mixer = parseMixer(args || {});
  send({ type: 'mixer', mixer });
}
