/*
 * Recognition engine: homr 0.7.0 segmentation + transformer decoding with
 * ONNX Runtime Web, ported from the 音鳥 Android app (PageSegmentation.kt,
 * StaffDecoder.kt, PageOmr.kt, PdfOmrEngine.kt, PageSymbolData.kt).
 * recognizePageData returns the same map as Android's recognizePage
 * (RecognizedPdfPage.symbolData() with the page layout).
 * homr is Copyright (c) Christian Liebhardt and contributors, AGPL-3.0.
 *
 * ORT runs on the main thread: its multi-threading deadlocks inside a Web
 * Worker. Threads need cross-origin isolation (COOP/COEP, see coi-sw.js).
 */
import * as ort from '../vendor/onnxruntime-web/ort.wasm.min.mjs';
import { detectStaves, restoreLeft } from './omr-geometry.js';
import { clahe, resizeLinear, pageX, prepareStaff, canvasFor, inkMask } from './omr-image.js';
import { analyze, systemToMap } from './omr-layout.js';
import { place, placeToList } from './omr-placement.js';
import { corroboratedEnds, measureCount } from './omr-evidence.js';

const ORT_VERSION = '1.22.0';
const ORT_BASE = new URL('../vendor/onnxruntime-web/', import.meta.url).href;

const MODEL_CACHE = 'ototori-models-homr-0.7';
const MODELS = ['segnet.onnx', 'encoder.onnx', 'decoder.onnx'];
const MODEL_SIZES = { 'segnet.onnx': 54.7e6, 'encoder.onnx': 50.4e6, 'decoder.onnx': 45.1e6 };
const WINDOW = 320;

/**
 * Version of the page-layout rules stored with cached pages (PdfOmrEngine.kt).
 * 2: a straight choir bracket is no longer a brace; a brace broken at its
 *    middle point is joined.
 * 3: token positions (snapped barlines/noteheads, staff lines per bar).
 * 4: a note head snaps to the found head nearest the decoder's x and right
 *    of the previous chord's head.
 */
export const LAYOUT_VERSION = 4;

let sessions = null;     // {seg, enc, dec, info}
let vocabulary = null;
let loading = null;      // Promise of the first ensureLoaded
let busy = Promise.resolve();  // one page at a time (the sessions are shared)

const now = () => performance.now();

function cancelledError() {
  const e = new Error('認識を中止しました。');
  e.name = 'Cancelled';
  return e;
}
const checkCancelled = (cancelled) => { if (cancelled && cancelled()) throw cancelledError(); };

/** The browser downloads the models on first use (Android: modelsReady after installing the bundle). */
export function modelsReady() { return true; }

export function isLoaded() { return sessions != null; }

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
    catch (e) { console.warn('モデルを端末に保存できませんでした（次回も再ダウンロードします）:', e); }
  }
  return buf.buffer;
}

/**
 * Downloads (or reads from the Cache API) the three models and creates the
 * ORT sessions, once. onProgress(stage, done, total): 'download' in bytes,
 * then 'session' 0..3.
 */
export function ensureLoaded({ threads = 4, onProgress = () => {} } = {}) {
  if (sessions) return Promise.resolve(sessions.info);
  if (!loading) {
    loading = load(threads, onProgress).catch((e) => { loading = null; throw e; });
  }
  return loading;
}

async function load(threads, onProgress) {
  ort.env.wasm.wasmPaths = ORT_BASE;
  ort.env.wasm.numThreads = self.crossOriginIsolated ? Math.max(1, threads) : 1;
  const t0 = now();
  const vocab = await (await fetch(new URL('../models/vocabulary.json', import.meta.url))).json();
  const buffers = {};
  const progress = {};
  const total = Object.values(MODEL_SIZES).reduce((a, b) => a + b, 0);
  let fromCache = true;
  for (const name of MODELS) {
    buffers[name] = await fetchModel(name, (bytes, cached) => {
      progress[name] = bytes; if (!cached) fromCache = false;
      onProgress('download', Object.values(progress).reduce((a, b) => a + b, 0), total);
    });
  }
  const downloadMs = now() - t0;
  onProgress('session', 0, 3);
  const options = { executionProviders: ['wasm'], graphOptimizationLevel: 'all' };
  const t1 = now();
  const seg = await ort.InferenceSession.create(buffers['segnet.onnx'], options);
  delete buffers['segnet.onnx'];
  onProgress('session', 1, 3);
  const enc = await ort.InferenceSession.create(buffers['encoder.onnx'], options);
  delete buffers['encoder.onnx'];
  onProgress('session', 2, 3);
  const dec = await ort.InferenceSession.create(buffers['decoder.onnx'], options);
  onProgress('session', 3, 3);
  const info = { threads: ort.env.wasm.numThreads, isolated: self.crossOriginIsolated, fromCache,
    downloadMs: Math.round(downloadMs), sessionMs: Math.round(now() - t1), ort: ORT_VERSION };
  vocabulary = vocab;
  sessions = { seg, enc, dec, info };
  return info;
}

/** PageSegmentation: 320 px patches, per-pixel argmax, overlaps averaged (integer). */
async function segment(gray, width, height, cancelled, onPatch) {
  const sums = new Uint16Array(gray.length);
  const counts = new Uint8Array(gray.length);
  const total = Math.ceil(Math.max(height, WINDOW) / WINDOW) * Math.ceil(Math.max(width, WINDOW) / WINDOW);
  let patches = 0;
  const patch = new Float32Array(3 * WINDOW * WINDOW);
  const plane = WINDOW * WINDOW;
  for (let row = 0; row < Math.max(height, WINDOW); row += WINDOW) {
    const y = Math.min(row, height - WINDOW);
    for (let column = 0; column < Math.max(width, WINDOW); column += WINDOW) {
      checkCancelled(cancelled);
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

/**
 * StaffDecoder.decode: 1280 x 256 canvas -> tokens [rhythm, pitch, lift,
 * position, articulation, slur, attention x (canvas px, NaN if none)].
 */
async function decodeStaff(canvas, cancelled, maxSteps = 608) {
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
    checkCancelled(cancelled);
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
  return { tokens, reachedEos: eos, encoderMs, decoderMs: now() - t1 };
}

/** SymbolVocabulary.decode: the six names of a token. */
function named(token) {
  const v = vocabulary;
  return [v.rhythm[token[0]], v.pitch[token[1]], v.lift[token[2]], v.position[token[3]], v.articulation[token[4]], v.slur[token[5]]];
}

/** Rendered RGBA page -> grayscale at the recognition width 1920 (as PdfPageRasterizer). */
export function pageGray(rgba, w, h) {
  const full = new Uint8Array(w * h);
  for (let i = 0, p = 0; i < full.length; i++, p += 4) full[i] = (77 * rgba[p] + 150 * rgba[p + 1] + 29 * rgba[p + 2] + 128) >> 8;
  const height = Math.round(h * (1920 / w));
  if (!(height > 0 && 1920 * height <= 16_000_000)) throw new Error('ページの縦横比が大きすぎます。');
  return { gray: resizeLinear(full, w, h, 1920, height), width: 1920, height };
}

/** FNV-1a of a canvas, for the decode memo (PageOmr's Pixels key). */
function hashPixels(bytes) {
  let h = 0x811c9dc5;
  for (let i = 0; i < bytes.length; i++) h = Math.imul(h ^ bytes[i], 0x01000193);
  return h >>> 0;
}

const sameBytes = (a, b) => {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
};

const sameSymbols = (a, b) => a.length === b.length && a.every((s, i) => s.every((v, k) => v === b[i][k]));
const noteCount = (symbols) => symbols.filter((s) => s[0].startsWith('note_') && s[1] !== '.').length;
const header = (symbols) => symbols.filter((s) => s[0].startsWith('clef_') || s[0].startsWith('keySignature_'));

/**
 * PageOmr.recognize on prepared staves: decodes every staff, retries a
 * staff whose measure count disagrees with barlines corroborated by both
 * neighbours, and collects the warnings. Returns {staves, warnings}; each
 * staff {geometry, crop, decoded, symbols}.
 */
async function recognizeStaves(gray, width, height, geometries, cancelled, onProgress, timing) {
  const warnings = [];
  if (geometries.length === 0) {
    warnings.push('五線を検出できませんでした。元のページを確認してください。');
    return { staves: [], warnings };
  }
  // Decodes by canvas content, so a canvas decoded twice (the neighbour
  // check below) runs once.
  const memo = new Map();  // hash -> [{pixels, result}]
  async function decode(pixels) {
    const key = hashPixels(pixels);
    const hit = (memo.get(key) || []).find((m) => sameBytes(m.pixels, pixels));
    if (hit) return hit.result;
    checkCancelled(cancelled);
    const result = await decodeStaff(pixels, cancelled);
    timing.encoder = (timing.encoder || 0) + result.encoderMs;
    timing.decoder = (timing.decoder || 0) + result.decoderMs;
    timing.staves = (timing.staves || 0) + 1;
    if (!memo.has(key)) memo.set(key, []);
    memo.get(key).push({ pixels, result });
    return result;
  }
  // Segmentation sometimes drops the left part of one staff. When both
  // neighbours agree, retain that area for inference and surface the
  // uncertainty rather than silently losing it.
  const primary = geometries.map((geometry, index) => {
    const neighbours = [];
    for (let k = Math.max(0, index - 2); k <= Math.min(geometries.length - 1, index + 2); k++) if (k !== index) neighbours.push(geometries[k]);
    const restored = restoreLeft(geometry, neighbours);
    return [restored, prepareStaff(gray, width, height, restored, geometries[index - 1], geometries[index + 1])];
  });
  const output = [];
  for (let index = 0; index < geometries.length; index++) {
    checkCancelled(cancelled);
    const before = geometries[index - 1], after = geometries[index + 1];
    const geometry = primary[index][0];
    if (geometry !== geometries[index]) warnings.push(`五線 ${index + 1}: 欠落を避けるため、左右の範囲を隣接する五線から補いました。`);
    if (geometry.inferredLine) warnings.push(`五線 ${index + 1}: 1 本の位置を推定しました。`);
    let canvas = primary[index][1];
    onProgress('staff', index, geometries.length);
    let decoded = await decode(canvas.pixels);
    let symbols = decoded.tokens.map(named);
    const ends = corroboratedEnds(gray, width, height, geometry, before, after);
    // Synchronized vocal stems can also align on three staves. Require both
    // neighbouring model decodes to independently agree with the image
    // count before changing this staff.
    let neighboursAgree = ends.length > 0 && measureCount(symbols) !== ends.length &&
      output.length > 0 && measureCount(output[output.length - 1].symbols) === ends.length && after != null;
    if (neighboursAgree) {
      const next = prepareStaff(gray, width, height, after, geometry, geometries[index + 2]);
      neighboursAgree = measureCount((await decode(next.pixels)).tokens.map(named)) === ends.length;
    }
    if (neighboursAgree) {
      const originalNotes = noteCount(symbols);
      const originalHeader = header(symbols);
      // A narrow crop can clip ledger notes/ottava marks. Keep the entire
      // horizontal staff and retry with more vertical context. Accept only
      // a complete decode agreeing with three image staves, preserving the
      // header and at least the original note count.
      for (const extra of [2.0, 6.0]) {
        checkCancelled(cancelled);
        const top = Math.max(0, Math.max(
          Math.trunc((before ? before.lines[before.lines.length - 1] : 0) + geometry.spacing),
          Math.trunc(canvas.bounds.top - extra * geometry.spacing)));
        if (top >= canvas.bounds.top) continue;
        const bounds = { ...canvas.bounds, top };
        const retryCanvas = { pixels: canvasFor(gray, width, height, geometry, bounds), bounds };
        const retry = await decode(retryCanvas.pixels);
        const retrySymbols = retry.tokens.map(named);
        if (retry.reachedEos && measureCount(retrySymbols) === ends.length &&
            noteCount(retrySymbols) >= originalNotes && sameSymbols(header(retrySymbols), originalHeader)) {
          const oldCount = measureCount(symbols);
          canvas = retryCanvas; decoded = retry; symbols = retrySymbols;
          warnings.push(`五線 ${index + 1}: 原譜と隣接する2本の五線の小節線を照合し、切り出し範囲を広げて再認識しました（${oldCount} → ${ends.length}小節）。音符は原譜で確認してください。`);
          break;
        }
      }
      if (measureCount(symbols) !== ends.length) {
        warnings.push(`五線 ${index + 1}: 原譜の小節線は${ends.length}小節、認識記号は${measureCount(symbols)}小節です。再認識では一致せず、原譜の確認が必要です。`);
      }
    }
    if (!decoded.reachedEos) warnings.push(`五線 ${index + 1}: 記号の生成が上限に達しました。`);
    output.push({ geometry, crop: canvas.bounds, decoded, symbols });
  }
  onProgress('staff', geometries.length, geometries.length);
  return { staves: output, warnings };
}

/**
 * PdfOmrEngine.analyzeLayout: ink mask, systems/braces/false staves, and
 * (when tokens are given for every staff) token places.
 * staves: [{lines, left, right, profile}]; tokens: per staff [{rhythm, pitch, x|null}].
 */
export function analyzeLayout(gray, width, height, staves, tokens = null) {
  const mask = inkMask(gray, width, height);
  const layout = analyze(mask, width, height, staves);
  if (tokens == null || tokens.length !== staves.length) return layout;
  layout.places = staves.map((s, i) => place(mask, width, height, s.lines, s.left, s.right, tokens[i]));
  return layout;
}

/** PageLayoutResult.toData */
export function layoutToData(layout) {
  const out = {
    systems: layout.systems.map(systemToMap),
    layout: { version: LAYOUT_VERSION, dropped_staves: layout.dropped, line_ink: layout.lineInk },
  };
  // Per staff, per token: null or [x, y|null, confidence, snapped, (five line heights)].
  if (layout.places) out.places = layout.places.map((staff) => staff.map(placeToList));
  return out;
}

/** Attention x in page pixels, or null when the decoder gave none. */
function tokenPageX(crop, token) {
  const x = token ? token[6] : NaN;
  return Number.isFinite(x) ? pageX(crop, x) : null;
}

/**
 * Recognises one rendered page (RGBA at 300 dpi, see PdfPageRasterizer).
 * Returns Android's recognizePage map: staves[{lines, left, right, profile,
 * crop, reachedEos, symbols}], warnings, width, height, systems,
 * layout{version, dropped_staves, line_ink}, places, timing.
 * cancelled(): true stops with an Error named 'Cancelled'.
 * onProgress(stage, done, total): 'segment' (patches), then 'staff'.
 */
export function recognizePageData(args) {
  const run = busy.then(() => recognizeNow(args));
  busy = run.catch(() => {});
  return run;
}

async function recognizeNow({ rgba, srcWidth, srcHeight, cancelled = () => false, onProgress = () => {} }) {
  if (!sessions) throw new Error('認識モデルを読み込んでいません。');
  checkCancelled(cancelled);
  const started = now();
  const timing = {};
  let t = now();
  const lap = (name) => { const n = now(); timing[name] = (timing[name] || 0) + (n - t); t = n; };
  const { gray, width, height } = pageGray(rgba, srcWidth, srcHeight);
  lap('gray');
  // PageOmr.detectStaves
  const adjusted = clahe(gray, width, height); lap('clahe');
  const labels = await segment(adjusted, width, height, cancelled, (done, total) => onProgress('segment', done, total));
  lap('segmentation');
  const geometries = detectStaves(labels, width, height); lap('geometry');
  checkCancelled(cancelled);
  const decodeStart = now();
  const page = await recognizeStaves(gray, width, height, geometries, cancelled, onProgress, timing);
  timing.decode_wall = now() - decodeStart;
  const tokens = page.staves.map((s) => s.symbols.map((sym, i) => ({
    rhythm: sym[0], pitch: sym[1], x: tokenPageX(s.crop, s.decoded.tokens[i]) })));
  const layoutStart = now();
  const layout = analyzeLayout(gray, width, height,
    page.staves.map((s) => ({ lines: s.geometry.lines, left: s.geometry.left, right: s.geometry.right, profile: s.geometry.profile })),
    tokens);
  timing.layout = now() - layoutStart;
  timing.total = now() - started;
  timing.threads = sessions.info.threads;
  timing.parallel_staves = 1;
  // PageSymbolData.kt symbolData()
  const staves = page.staves.map((s) => {
    const c = s.crop;
    return {
      lines: s.geometry.lines, left: s.geometry.left, right: s.geometry.right,
      // (x, offset of the lines) along a tilted or bent staff; empty when straight.
      profile: (s.geometry.profile || []).map(([x, o]) => [Math.round(x * 10) / 10, Math.round(o * 100) / 100]),
      crop: [c.left, c.top, c.right, c.bottom],
      reachedEos: s.decoded.reachedEos,
      // Attention x in page pixels (grand-staff timing) as a 7th field; omitted when unknown.
      symbols: s.symbols.map((sym, i) => {
        const x = tokenPageX(c, s.decoded.tokens[i]);
        return x == null ? [...sym] : [...sym, x];
      }),
    };
  });
  const timingOut = {};
  for (const [k, v] of Object.entries(timing)) timingOut[k] = Math.round(v);
  return { staves, warnings: page.warnings, width, height, ...layoutToData(layout), timing: timingOut };
}

/**
 * PdfOmrEngine.layoutForCached: layout and token places for a page cached
 * with an older LAYOUT_VERSION, from the rendered page (no model inference).
 * Returns {systems, layout, places}.
 */
export function relayoutPageData({ rgba, srcWidth, srcHeight, data }) {
  const { gray, width, height } = pageGray(rgba, srcWidth, srcHeight);
  if (height !== data.height) throw new Error('ページの描画サイズが保存結果と一致しません。');
  const items = data.staves || [];
  const staves = items.map((staff) => ({
    lines: (staff.lines || []).map(Number),
    left: Number.isInteger(staff.left) ? staff.left : staff.crop[0],
    right: Number.isInteger(staff.right) ? staff.right : staff.crop[2],
    profile: (staff.profile || []).filter((p) => Array.isArray(p) && p.length === 2).map(([x, o]) => [Number(x), Number(o)]),
  }));
  const tokens = items.map((staff) => staff.symbols.map((s) => ({
    rhythm: s[0], pitch: s[1], x: typeof s[6] === 'number' ? s[6] : null })));
  return layoutToData(analyzeLayout(gray, width, height, staves, tokens));
}
