/*
 * Parity test driver (not deployed): renders sample PDFs as the app does
 * (pdf.js, 300 dpi, intent 'print'), runs omr-engine.recognizePageData and
 * saves each page's result through serve.py for compare.py.
 * State for automation: window.parity = {status, done, total, errors, log}.
 */
import * as pdfjs from '../vendor/pdfjs/pdf.min.mjs';
import * as engine from '../js/omr-engine.js';
import { textLabels } from '../js/text-labels.js';

pdfjs.GlobalWorkerOptions.workerSrc = new URL('../vendor/pdfjs/pdf.worker.min.mjs', import.meta.url).href;

const params = new URLSearchParams(location.search);
const songs = (params.get('songs') || params.get('song') || 'tsubaki').split(',').filter(Boolean);
const threads = Number(params.get('threads') || 4);
const pageFilter = params.get('pages');  // e.g. "1-3" or "2,5"
const tag = params.get('tag') || 'web300';
// ?base=<folder with <song>/<song>.pdf>, relative to this page (default: the repo's samples/).
const samples = new URL(params.get('base') || '../../../../samples/', location.href);

const state = { status: 'starting', done: 0, total: 0, errors: [], log: [] };
window.parity = state;
const logEl = document.getElementById('log');
function log(line) { state.log.push(line); logEl.textContent += line + '\n'; console.log(line); }

function wanted(n) {
  if (!pageFilter) return true;
  return pageFilter.split(',').some((part) => {
    const [a, b] = part.split('-').map(Number);
    return b ? n >= a && n <= b : n === a;
  });
}

/** Same rule as pdf-source.js renderScale (PdfPageRasterizer): dpi, at most 3840 px wide, ≤ 16 Mpx. */
function renderScale(w, h, dpi = 300) {
  let scale = Math.min(dpi / 72, 3840 / w);
  if (w * h * scale * scale > 16_000_000) scale = Math.sqrt(16_000_000 / (w * h));
  return scale;
}

async function renderPage(doc, number) {
  const page = await doc.getPage(number);
  try {
    const base = page.getViewport({ scale: 1 });
    const viewport = page.getViewport({ scale: renderScale(base.width, base.height) });
    const canvas = document.createElement('canvas');
    canvas.width = Math.max(1, Math.ceil(viewport.width));
    canvas.height = Math.max(1, Math.ceil(viewport.height));
    const ctx = canvas.getContext('2d', { willReadFrequently: true });
    ctx.fillStyle = '#fff';
    ctx.fillRect(0, 0, canvas.width, canvas.height);
    // 'print': no requestAnimationFrame, so a hidden pane does not stall.
    await page.render({ canvasContext: ctx, viewport, background: 'rgb(255,255,255)', intent: 'print' }).promise;
    const image = ctx.getImageData(0, 0, canvas.width, canvas.height);
    canvas.width = canvas.height = 0;
    return image;
  } finally { page.cleanup(); }
}

async function save(path, value) {
  const response = await fetch('/save?path=' + encodeURIComponent(path), { method: 'POST', body: JSON.stringify(value) });
  if (!response.ok) throw new Error(`save ${path}: ${response.status}`);
}

/** ?labelsOnly: re-save labels-N.json only (no recognition), e.g. after a text-labels.js change. */
async function labelsOnly() {
  state.status = 'running';
  for (const song of songs) {
    const bytes = new Uint8Array(await (await fetch(new URL(`${song}/${song}.pdf`, samples))).arrayBuffer());
    const doc = await pdfjs.getDocument({ data: bytes, isEvalSupported: false }).promise;
    for (let n = 1; n <= doc.numPages; n++) {
      if (!wanted(n)) continue;
      state.total++;
      const page = await doc.getPage(n);
      try { await save(`${tag}/${song}/labels-${n}.json`, await textLabels(page)); } finally { page.cleanup(); }
      state.done++;
    }
  }
  state.status = 'finished';
  log(`labels finished: ${state.done} pages`);
}

async function main() {
  if (params.has('labelsOnly')) return labelsOnly();
  log(`isolated=${self.crossOriginIsolated} threads=${threads}`);
  state.status = 'loading';
  const info = await engine.ensureLoaded({ threads, onProgress: (stage, done, total) => { state.load = { stage, done, total }; } });
  log('loaded ' + JSON.stringify(info));
  const docs = [];
  for (const song of songs) {
    const bytes = new Uint8Array(await (await fetch(new URL(`${song}/${song}.pdf`, samples))).arrayBuffer());
    const doc = await pdfjs.getDocument({ data: bytes, isEvalSupported: false }).promise;
    const pages = [];
    for (let n = 1; n <= doc.numPages; n++) if (wanted(n)) pages.push(n);
    docs.push({ song, doc, pages });
    state.total += pages.length;
  }
  state.status = 'running';
  if (params.has('cancelTest')) {
    // Cancel after N ms (segment stage by default), then expect an Error named 'Cancelled'.
    const after = Number(params.get('cancelTest') || 3000);
    const { song, doc, pages } = docs[0];
    const image = await renderPage(doc, pages[0]);
    const t0 = performance.now();
    try {
      await engine.recognizePageData({ rgba: image.data, srcWidth: image.width, srcHeight: image.height,
        cancelled: () => performance.now() - t0 > after, onProgress: (stage, done, total) => { state.progress = { stage, done, total }; } });
      log(`cancel test ${song}: NOT cancelled`);
    } catch (e) {
      log(`cancel test ${song}: ${e.name} "${e.message}" after ${Math.round(performance.now() - t0)} ms at ${JSON.stringify(state.progress)}`);
    }
  }
  for (const { song, doc, pages } of docs) {
    for (const n of pages) {
      const t0 = performance.now();
      try {
        const image = await renderPage(doc, n);
        const renderMs = Math.round(performance.now() - t0);
        const data = await engine.recognizePageData({ rgba: image.data, srcWidth: image.width, srcHeight: image.height,
          cancelled: () => false, onProgress: (stage, done, total) => { state.progress = { song, page: n, stage, done, total }; } });
        data.timing.render = renderMs;
        await save(`${tag}/${song}/page-${n}.json`, data);
        // ?labels: also the PDF text layer as the web app reads it (part names, tempo).
        if (params.has('labels')) {
          const page = await doc.getPage(n);
          try { await save(`${tag}/${song}/labels-${n}.json`, await textLabels(page)); } finally { page.cleanup(); }
        }
        log(`${song} p${n}: ${image.width}x${image.height} staves=${data.staves.length} ${Math.round(performance.now() - t0)} ms`);
      } catch (e) {
        state.errors.push(`${song} p${n}: ${e.stack || e}`);
        log(`${song} p${n}: ERROR ${e.stack || e}`);
      }
      state.done++;
    }
  }
  state.status = 'finished';
  log('finished');
}

main().catch((e) => { state.status = 'failed'; state.errors.push(String(e.stack || e)); log('FAILED ' + (e.stack || e)); });
