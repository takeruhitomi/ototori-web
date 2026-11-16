/*
 * Recognition engine: homr 0.7.0 segmentation + transformer decoding with
 * ONNX Runtime Web, ported from the 音鳥 Android app (PageSegmentation.kt,
 * StaffDecoder.kt, PageOmr.kt).
 * homr is Copyright (c) Christian Liebhardt and contributors, AGPL-3.0.
 */
import * as ort from '../vendor/onnxruntime-web/ort.wasm.min.mjs';
import { detectStaves, restoreLeft } from './omr-geometry.js';
import { clahe, resizeLinear, pageX, prepareStaff } from './omr-image.js';

const ORT_VERSION = '1.22.0';
const ORT_BASE = new URL('../vendor/onnxruntime-web/', import.meta.url).href;

const MODEL_CACHE = 'ototori-models-homr-0.7';
const MODELS = ['segnet.onnx', 'encoder.onnx', 'decoder.onnx'];
const WINDOW = 320;
let sessions = null;
let vocabulary = null;

let listener = () => {};
/** Receives {type, ...} events: progress, loaded, gray, staves, staff, done, log. */
export function setListener(fn) { listener = fn; }
const post = (type, data = {}) => listener({ type, ...data });
const now = () => performance.now();

async function fetchModel(name, onBytes) {
  const url = new URL('../models/' + name, import.meta.url).href;
  let cache = null;
  try { cache = await caches.open(MODEL_CACHE); } catch (e) { cache = null; }
  const cached = cache ? await cache.match(url) : null;
  if (cached) { const buf = await cached.arrayBuffer(); onBytes(buf.byteLength, true); return buf; }
  const response = await fetch(url);
  if (!response.ok) throw new Error(`${name} を取得できませんでした (${response.status})`);
  const reader = response.body.getReader();
  const chunks = [];
  let received = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    chunks.push(value); received += value.length; onBytes(received, false);
  }
  const buf = new Uint8Array(received);
  let offset = 0;
  for (const c of chunks) { buf.set(c, offset); offset += c.length; }
  if (cache) {
    try { await cache.put(url, new Response(buf.slice().buffer, { headers: { 'content-type': 'application/octet-stream' } })); }
    catch (e) { post('log', { message: 'モデルを端末に保存できませんでした（次回も再ダウンロードします）: ' + e.message }); }
  }
  return buf.buffer;
}

export async function load({ threads }) {
  if (sessions) { post('loaded', { info: sessions.info }); return; }
  ort.env.wasm.wasmPaths = ORT_BASE;
  ort.env.wasm.numThreads = self.crossOriginIsolated ? Math.max(1, threads) : 1;
  const t0 = now();
  const vocab = await (await fetch(new URL('../models/vocabulary.json', import.meta.url))).json();
  vocabulary = vocab;
  const buffers = {};
  const sizes = { 'segnet.onnx': 54.7e6, 'encoder.onnx': 50.4e6, 'decoder.onnx': 45.1e6 };
  const progress = {};
  let fromCache = true;
  for (const name of MODELS) {
    buffers[name] = await fetchModel(name, (bytes, cached) => {
      progress[name] = bytes; if (!cached) fromCache = false;
      const done = Object.values(progress).reduce((a, b) => a + b, 0);
      post('progress', { stage: 'download', done, total: Object.values(sizes).reduce((a, b) => a + b, 0) });
    });
  }
  const downloadMs = now() - t0;
  post('progress', { stage: 'session', done: 0, total: 3 });
  const options = { executionProviders: ['wasm'], graphOptimizationLevel: 'all' };
  const t1 = now();
  const seg = await ort.InferenceSession.create(buffers['segnet.onnx'], options);
  post('progress', { stage: 'session', done: 1, total: 3 });
  const enc = await ort.InferenceSession.create(buffers['encoder.onnx'], options);
  post('progress', { stage: 'session', done: 2, total: 3 });
  const dec = await ort.InferenceSession.create(buffers['decoder.onnx'], options);
  const info = { threads: ort.env.wasm.numThreads, isolated: self.crossOriginIsolated, fromCache,
    downloadMs: Math.round(downloadMs), sessionMs: Math.round(now() - t1), ort: ORT_VERSION };
  sessions = { seg, enc, dec, info };
  post('loaded', { info });
}

async function segment(gray, width, height, onPatch) {
  const sums = new Uint16Array(gray.length);
  const counts = new Uint8Array(gray.length);
  const total = Math.ceil(Math.max(height, WINDOW) / WINDOW) * Math.ceil(Math.max(width, WINDOW) / WINDOW);
  let patches = 0;
  const patch = new Float32Array(3 * WINDOW * WINDOW);
  const plane = WINDOW * WINDOW;
  for (let row = 0; row < Math.max(height, WINDOW); row += WINDOW) {
    const y = Math.min(row, height - WINDOW);
    for (let column = 0; column < Math.max(width, WINDOW); column += WINDOW) {
      const x = Math.min(column, width - WINDOW);
      const x0 = Math.max(0, x), y0 = Math.max(0, y);
      const x1 = Math.min(width, x + WINDOW), y1 = Math.min(height, y + WINDOW);
      patch.fill(255);
      for (let py = 0; py < y1 - y0; py++) {
        for (let px = 0; px < x1 - x0; px++) {
          const v = gray[(y0 + py) * width + x0 + px];
          const i = py * WINDOW + px;
          patch[i] = v; patch[plane + i] = v; patch[2 * plane + i] = v;
        }
      }
      const input = new ort.Tensor('float32', patch, [1, 3, WINDOW, WINDOW]);
      const out = await sessions.seg.run({ input });
      const logits = out.output.data;
      for (let py = 0; py < y1 - y0; py++) {
        for (let px = 0; px < x1 - x0; px++) {
          const i = py * WINDOW + px;
          let best = -Infinity, label = 0;
          for (let c = 0; c < 6; c++) { const v = logits[c * plane + i]; if (v > best) { best = v; label = c; } }
          const d = (y0 + py) * width + x0 + px;
          sums[d] += label; counts[d]++;
        }
      }
      out.output.dispose?.();
      patches++;
      onPatch(patches, total);
    }
  }
  const labels = new Uint8Array(gray.length);
  for (let i = 0; i < labels.length; i++) labels[i] = counts[i] === 0 ? 0 : Math.trunc(sums[i] / counts[i]);
  return labels;
}

function argmax(data) {
  let best = -Infinity, index = 0;
  for (let i = 0; i < data.length; i++) if (data[i] > best) { best = data[i]; index = i; }
  return index;
}

const int64 = (v) => new ort.Tensor('int64', BigInt64Array.from([BigInt(v)]), [1, 1]);

async function decodeStaff(canvas, maxSteps = 608) {
  const pixels = new Float32Array(canvas.length);
  for (let i = 0; i < canvas.length; i++) pixels[i] = (canvas[i] / 255 - 0.7931) / 0.1738;
  const t0 = now();
  const encoded = await sessions.enc.run({ input: new ort.Tensor('float32', pixels, [1, 1, 256, 1280]) });
  const context = encoded.output;
  const encoderMs = now() - t0;
  const reduced = new ort.Tensor('float32', context.data.slice(0, 512), [1, 1, 512]);
  const t1 = now();
  const tokens = [];
  let cache = [];
  for (let i = 0; i < 32; i++) cache.push(new ort.Tensor('float32', new Float32Array(0), [1, 8, 0, 64]));
  let rhythm = 1, pitch = 0, lift = 0, articulation = 0, slur = 0, eos = false;
  for (let step = 0; step < maxSteps; step++) {
    const feeds = {
      rhythms: int64(rhythm), pitchs: int64(pitch), lifts: int64(lift), articulations: int64(articulation),
      slurs: int64(slur), context: step === 0 ? context : reduced,
      cache_len: new ort.Tensor('int64', BigInt64Array.from([BigInt(step)]), [1]),
    };
    for (let i = 0; i < 32; i++) feeds['cache_in' + i] = cache[i];
    const out = await sessions.dec.run(feeds);
    rhythm = argmax(out.out_rhythms.data); pitch = argmax(out.out_pitchs.data); lift = argmax(out.out_lifts.data);
    const position = argmax(out.out_positions.data);
    articulation = argmax(out.out_articulations.data); slur = argmax(out.out_slurs.data);
    cache = [];
    for (let i = 0; i < 32; i++) cache.push(out['cache_out' + i]);
    if (rhythm === 2) { eos = true; break; }
    const att = out.attention.data;
    tokens.push([rhythm, pitch, lift, position, articulation, slur, att.length > 0 ? att[0] : NaN]);
  }
  return { tokens, eos, encoderMs, decoderMs: now() - t1 };
}

function named(token) {
  const v = vocabulary;
  return [v.rhythm[token[0]], v.pitch[token[1]], v.lift[token[2]], v.position[token[3]], v.articulation[token[4]], v.slur[token[5]]];
}

/** Rendered RGBA page -> grayscale at the recognition width 1920 (as PdfPageRasterizer). */
function pageGray(rgba, w, h) {
  const full = new Uint8Array(w * h);
  for (let i = 0, p = 0; i < full.length; i++, p += 4) full[i] = (77 * rgba[p] + 150 * rgba[p + 1] + 29 * rgba[p + 2] + 128) >> 8;
  const height = Math.round(h * (1920 / w));
  return { gray: resizeLinear(full, w, h, 1920, height), width: 1920, height };
}

export async function recognize({ rgba, srcWidth, srcHeight }) {
  const timing = {};
  const lap = (name, t) => { timing[name] = Math.round((timing[name] || 0) + now() - t); };
  let t = now();
  const { gray, width, height } = pageGray(rgba, srcWidth, srcHeight);
  lap('gray', t);
  post('gray', { gray, width, height });
  t = now();
  const adjusted = clahe(gray, width, height); lap('clahe', t);
  t = now();
  const labels = await segment(adjusted, width, height, (done, total) => post('progress', { stage: 'segment', done, total }));
  lap('segmentation', t);
  t = now();
  const geometries = detectStaves(labels, width, height); lap('geometry', t);
  post('staves', { staves: geometries });
  const staves = [];
  for (let index = 0; index < geometries.length; index++) {
    post('progress', { stage: 'staff', done: index, total: geometries.length });
    const neighbours = [];
    for (let k = Math.max(0, index - 2); k <= Math.min(geometries.length - 1, index + 2); k++) if (k !== index) neighbours.push(geometries[k]);
    const geometry = restoreLeft(geometries[index], neighbours);
    const prepared = prepareStaff(gray, width, height, geometry, geometries[index - 1], geometries[index + 1]);
    const result = await decodeStaff(prepared.pixels);
    timing.encoder = Math.round((timing.encoder || 0) + result.encoderMs);
    timing.decoder = Math.round((timing.decoder || 0) + result.decoderMs);
    const b = prepared.bounds;
    const symbols = result.tokens.map((tk) => {
      const s = named(tk);
      s.push(Number.isFinite(tk[6]) ? pageX(b, tk[6]) : null);
      return s;
    });
    const staff = { lines: geometry.lines, left: geometry.left, right: geometry.right, profile: geometry.profile,
      crop: [b.left, b.top, b.right, b.bottom], reachedEos: result.eos, symbols,
      restoredLeft: geometry !== geometries[index], inferredLine: geometry.inferredLine };
    staves.push(staff);
    post('staff', { index, staff, encoderMs: Math.round(result.encoderMs), decoderMs: Math.round(result.decoderMs) });
  }
  post('progress', { stage: 'staff', done: geometries.length, total: geometries.length });
  post('done', { page: { staves, width, height, timing } });
}
