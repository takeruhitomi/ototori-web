/*
 * PDF sources with pdf.js: picking, page counts, previews and the 300 dpi
 * page images for recognition (Android: MainActivity's PdfRenderer use and
 * PdfPageRasterizer.kt).
 */
import * as pdfjs from '../vendor/pdfjs/pdf.min.mjs';
import * as storage from './storage.js';
import * as files from './files.js';

pdfjs.GlobalWorkerOptions.workerSrc = new URL('../vendor/pdfjs/pdf.worker.min.mjs', import.meta.url).href;

/** Same rule as PdfPageRasterizer: dpi scale, at most 3840 px wide; within iOS canvas limits. */
const MAX_RENDER_WIDTH = 3840;
const MAX_CANVAS_AREA = 16_000_000;

const documents = new Map(); // hash -> Promise<PDFDocumentProxy> (a few recent ones)
let current = null;          // {hash, doc}: the PDF "opened" for recognizePage/renderPage

function loadDocument(hash) {
  if (!documents.has(hash)) {
    const loading = storage.pdfBytes(hash).then((bytes) => {
      if (!bytes) throw new Error('保存した PDF が見つかりません。');
      return pdfjs.getDocument({ data: bytes, isEvalSupported: false }).promise;
    });
    documents.set(hash, loading);
    loading.catch(() => documents.delete(hash));
    while (documents.size > 3) {
      const [oldest, doc] = documents.entries().next().value;
      if (current?.hash === oldest) break;
      documents.delete(oldest);
      doc.then((d) => d.destroy()).catch(() => {});
    }
  }
  return documents.get(hash);
}

async function pageCountOf(bytes) {
  const doc = await pdfjs.getDocument({ data: bytes.slice(), isEvalSupported: false }).promise;
  try { return doc.numPages; } finally { doc.destroy(); }
}

async function importFile(file) {
  const bytes = new Uint8Array(await file.arrayBuffer());
  const pages = await pageCountOf(bytes);
  if (!(pages > 0)) throw new Error('ページがありません。');
  const hash = await storage.importPdf(bytes);
  return { name: file.name || 'PDF', pages, sourceHash: hash };
}

/** Batch conversion: several PDFs; null when cancelled (as Android). */
export async function pickPdfs() {
  const picked = await files.pickFiles({ accept: 'application/pdf,.pdf', multiple: true });
  if (!picked.length) return null;
  const out = [];
  for (const file of picked) {
    try { out.push(await importFile(file)); }
    catch (e) { out.push({ name: file.name || 'PDF', error: `PDFを開けません: ${e.message}` }); }
  }
  return out;
}

/** One PDF, which also becomes the open document. */
export async function pickPdf() {
  const [file] = await files.pickFiles({ accept: 'application/pdf,.pdf', multiple: false });
  if (!file) return null;
  const result = await importFile(file);
  current = { hash: result.sourceHash, doc: await loadDocument(result.sourceHash) };
  return result;
}

export async function openSource(hash, pages) {
  const doc = await loadDocument(hash);
  if (pages != null && pages !== doc.numPages) throw new Error('保存されたページ数と一致しません。');
  current = { hash, doc };
  return { pages: doc.numPages, sourceHash: hash };
}

export function currentHash() { return current?.hash ?? null; }

function requireCurrent() {
  if (!current) throw new Error('PDFを選択してください。');
  return current;
}

async function drawPage(doc, index, scaleFor) {
  if (!(index >= 0 && index < doc.numPages)) throw new Error('ページ番号が範囲外です。');
  const page = await doc.getPage(index + 1);
  try {
    // Android's PdfRenderer reports whole points (e.g. A4 595.28 pt -> 595);
    // size the image from those so it matches Android's pixel size.
    const base = page.getViewport({ scale: 1 });
    const w = Math.max(1, Math.floor(base.width)), h = Math.max(1, Math.floor(base.height));
    const scale = scaleFor(w, h);
    const viewport = page.getViewport({ scale });
    const canvas = document.createElement('canvas');
    canvas.width = Math.max(1, Math.ceil(w * scale));
    canvas.height = Math.max(1, Math.ceil(h * scale));
    const ctx = canvas.getContext('2d', { willReadFrequently: true });
    ctx.fillStyle = '#fff';
    ctx.fillRect(0, 0, canvas.width, canvas.height);
    // 'print': no requestAnimationFrame, so a hidden tab does not stall.
    await page.render({ canvasContext: ctx, viewport, background: 'rgb(255,255,255)', intent: 'print' }).promise;
    return canvas;
  } finally { page.cleanup(); }
}

function renderScale(dpi) {
  return (w, h) => {
    let scale = Math.min(dpi / 72, MAX_RENDER_WIDTH / w);
    if (w * h * scale * scale > MAX_CANVAS_AREA) scale = Math.sqrt(MAX_CANVAS_AREA / (w * h));
    return scale;
  };
}

async function png(canvas) {
  const blob = await new Promise((resolve, reject) =>
    canvas.toBlob((b) => (b ? resolve(b) : reject(new Error('画像を作れませんでした。'))), 'image/png'));
  return new Uint8Array(await blob.arrayBuffer());
}

function scaled(canvas, maxSide) {
  const scale = Math.min(1, maxSide / Math.max(canvas.width, canvas.height));
  if (scale >= 1) return canvas;
  const small = document.createElement('canvas');
  small.width = Math.max(1, Math.round(canvas.width * scale));
  small.height = Math.max(1, Math.round(canvas.height * scale));
  const ctx = small.getContext('2d');
  ctx.imageSmoothingQuality = 'high';
  ctx.drawImage(canvas, 0, 0, small.width, small.height);
  return small;
}

/** The original page as PNG for the practice screen (long side ≤ 1600 px, ≤ 2x). */
export async function renderSourcePage(hash, page) {
  const doc = await loadDocument(hash);
  const canvas = await drawPage(doc, page, (w, h) => Math.min(2, 1600 / Math.max(w, h)));
  try { return await png(canvas); } finally { canvas.width = canvas.height = 0; }
}

/** Android's renderPage diagnostics: full-size render, small PNG preview. */
export async function renderPreview(page, dpi) {
  if (dpi !== 300 && dpi !== 400) throw new Error('解像度が不正です。');
  const { doc } = requireCurrent();
  const started = performance.now();
  const canvas = await drawPage(doc, page, renderScale(dpi));
  const elapsedMs = Math.round(performance.now() - started);
  try {
    const preview = await png(scaled(canvas, 1200));
    return { width: canvas.width, height: canvas.height, elapsedMs, pssBytes: 0,
      bitmapBytes: canvas.width * canvas.height * 4, preview };
  } finally { canvas.width = canvas.height = 0; }
}

/** RGBA pixels of a page at the recognition resolution. */
export async function renderForRecognition(hash, page, dpi) {
  const doc = await loadDocument(hash);
  const canvas = await drawPage(doc, page, renderScale(dpi));
  try {
    const image = canvas.getContext('2d').getImageData(0, 0, canvas.width, canvas.height);
    return { rgba: image.data, width: image.width, height: image.height, pages: doc.numPages };
  } finally { canvas.width = canvas.height = 0; }
}

export async function pageCount(hash) { return (await loadDocument(hash)).numPages; }
