/*
 * Recognition jobs in the browser (Android: ConversionService.kt and the
 * recognizePage / readPageLabels handlers of MainActivity.kt).
 *
 * The Dart UI saves a job, calls start(id) and polls state(id); pages are
 * recognised one at a time and cached, so an interrupted job resumes from
 * the saved pages. There is no background service: the page must stay open
 * (a screen wake lock is held while a job runs).
 */
import * as storage from './storage.js';
import * as engine from './omr-engine.js';
import * as pdfSource from './pdf-source.js';
import * as pdfjs from '../vendor/pdfjs/pdf.min.mjs';
import { showProgress, hideProgress } from './progress.js';

let run = null;          // {id, cancelled, reason}: the job being recognised
let single = false;      // a recognizePage call is running

const threads = () => Math.min(4, navigator.hardwareConcurrency || 1);
const cancelledError = () => Object.assign(new Error('認識を中止しました'), { name: 'Cancelled' });

export const activeId = () => run?.id ?? null;
export const busy = () => run !== null || single;

export function cancel(id) {
  if (run && (id == null || run.id === id)) run.cancelled = true;
}
export function cancelForPlayback() {
  if (run) { run.reason = '再生を優先するため認識を中断しました。保存済みページから再開できます。'; run.cancelled = true; }
}

async function ensureModels() {
  if (engine.isLoaded()) return;
  try {
    await engine.ensureLoaded({ threads: threads(), onProgress: (stage, done, total) => {
      if (stage === 'download') showProgress(`認識モデルをダウンロードしています ${Math.round(done / 1e6)} / ${Math.round(total / 1e6)} MB（初回のみ）`, done / total);
      else showProgress('認識モデルを準備しています', done / Math.max(1, total));
    } });
  } finally { hideProgress(); }
}

let wakeLock = null;
async function holdScreen() {
  try { wakeLock = await navigator.wakeLock?.request('screen'); } catch { wakeLock = null; }
}
function releaseScreen() { wakeLock?.release().catch(() => {}); wakeLock = null; }
document.addEventListener('visibilitychange', () => {
  // A wake lock is released when the page is hidden; take it again on return.
  if (document.visibilityState === 'visible' && run && !wakeLock) holdScreen();
});

async function recognizeOne(hash, index, dpi, cancelled, label) {
  const image = await pdfSource.renderForRecognition(hash, index, dpi);
  if (cancelled()) throw cancelledError();
  return engine.recognizePageData({ rgba: image.rgba, srcWidth: image.width, srcHeight: image.height, cancelled,
    onProgress: (stage, done, total) => showProgress(stage === 'segment'
      ? `${label}・五線と記号の位置を探しています ${done} / ${total}`
      : `${label}・五線を読み取っています ${done} / ${total}`, total > 0 ? done / total : 0) });
}

/** Single page (the Dart pass that assembles a converted score reads every page this way). */
export async function recognizePage(page, dpi) {
  if (dpi !== 300 && dpi !== 400 || !(page >= 0)) throw Object.assign(new Error('ページまたは解像度が不正です。'), { code: 'input' });
  const hash = pdfSource.currentHash();
  if (!hash) throw new Error('PDFを選択してください。');
  const cached = await storage.readRecognition(hash, page, dpi);
  if (cached) return cached;
  if (run) throw new Error('保存した変換ジョブが実行中です。');
  if (single) throw new Error('別の認識が実行中です。');
  single = true;
  try {
    await ensureModels();
    const data = await recognizeOne(hash, page, dpi, () => false, `${page + 1}ページ`);
    await storage.writeRecognition(hash, page, dpi, data);
    return data;
  } finally { single = false; hideProgress(); }
}

function persist(id, data, status, completed) {
  data.status = status;
  data.completed_pages = [...completed].sort((a, b) => a - b);
  data.error = null;
  return storage.saveConversion(id, JSON.stringify(data));
}

async function execute(token) {
  let data = null;
  try {
    data = JSON.parse(await storage.loadConversion(token.id));
    if (token.cancelled) throw cancelledError();
    await holdScreen();
    const settings = data.settings;
    const hash = settings.source_hash, dpi = settings.dpi, count = settings.pages;
    const selected = settings.all_pages ? [...Array(count).keys()] : [settings.selected_page];
    const completed = new Set();
    await persist(token.id, data, 'running', completed);
    if (await pdfSource.pageCount(hash) !== count) throw new Error('PDF のページ数が保存設定と一致しません。');
    const missing = [];
    for (const index of selected) {
      if (await storage.readRecognition(hash, index, dpi)) completed.add(index); else missing.push(index);
    }
    if (completed.size) await persist(token.id, data, 'running', completed);
    if (missing.length) await ensureModels();
    const cancelled = () => token.cancelled;
    for (const index of missing) {
      if (token.cancelled) throw cancelledError();
      const output = await recognizeOne(hash, index, dpi, cancelled, `${index + 1} / ${count} ページ`);
      await storage.writeRecognition(hash, index, dpi, output);
      completed.add(index);
      await persist(token.id, data, 'running', completed);
    }
    if (token.cancelled) throw cancelledError();
    await persist(token.id, data, 'recognized', completed);
  } catch (e) {
    const message = token.cancelled || e?.name === 'Cancelled' ? (token.reason ?? '認識を中止しました')
      : /memory|メモリ|allocation|out of bounds/i.test(String(e?.message)) ? 'メモリ不足で認識を中断しました。保存したページから再開できます'
      : `認識に失敗しました: ${e?.message ?? e}`;
    if (data) {
      try {
        data.status = token.cancelled || e?.name === 'Cancelled' ? 'cancelled' : 'failed';
        data.error = message;
        await storage.saveConversion(token.id, JSON.stringify(data));
      } catch (saveError) { console.error('Cannot save failure state', saveError); }
    }
  } finally {
    releaseScreen();
    hideProgress();
    if (run === token) run = null;
  }
}

export async function start(id) {
  if (!id) throw new Error('変換ジョブが必要です。');
  await storage.loadConversion(id); // must exist
  if (run?.id === id) return null;
  if (run || single) throw new Error('別の認識が実行中です。');
  const token = { id, cancelled: false, reason: null };
  run = token;
  execute(token); // runs on; state() reports progress
  return null;
}

export async function state(id) {
  const wasActive = run?.id === id;
  const text = await storage.loadConversion(id);
  return { active: wasActive || run?.id === id, text };
}

/**
 * Printed text for part names and the tempo mark. Android reads it with
 * ML Kit OCR; the browser has no OCR, so the PDF's own text layer is used
 * (present in PDFs exported from notation software, absent in scans).
 * Boxes are in the 1920-px-wide page frame, one entry per text line.
 */
export async function readPageLabels(index) {
  const hash = pdfSource.currentHash();
  if (!hash) throw new Error('PDFを選択してください。');
  const bytes = await storage.pdfBytes(hash);
  const doc = await pdfjs.getDocument({ data: bytes, isEvalSupported: false }).promise;
  try {
    if (!(index >= 0 && index < doc.numPages)) throw new Error('ページ番号が範囲外です。');
    const page = await doc.getPage(index + 1);
    const base = page.getViewport({ scale: 1 });
    const viewport = page.getViewport({ scale: 1920 / base.width });
    const content = await page.getTextContent();
    const runs = [];
    for (const item of content.items) {
      const text = (item.str || '').trim();
      if (!text) continue;
      const [a, b, c, d, e, f] = pdfjs.Util.transform(viewport.transform, item.transform);
      const height = Math.hypot(c, d);
      const width = item.width * viewport.scale;
      if (!(height > 0) || Math.abs(b) > Math.abs(a)) continue; // vertical text
      runs.push({ text, left: e, right: e + Math.max(width, height * 0.5), top: f - height, bottom: f, height });
    }
    // Join runs on one baseline into lines, as OCR reports lines.
    runs.sort((p, q) => p.bottom - q.bottom || p.left - q.left);
    const lines = [];
    for (const r of runs) {
      const line = lines.find((l) => Math.abs(l.bottom - r.bottom) < 0.35 * r.height &&
        r.left - l.right < 1.5 * r.height && l.left - r.right < 1.5 * r.height);
      if (line) {
        const before = r.left < line.left;
        line.text = before ? `${r.text} ${line.text}` : `${line.text} ${r.text}`;
        line.left = Math.min(line.left, r.left); line.right = Math.max(line.right, r.right);
        line.top = Math.min(line.top, r.top); line.bottom = Math.max(line.bottom, r.bottom);
      } else lines.push({ ...r });
    }
    const labels = lines.slice(0, 2000).map((l) => {
      const box = [Math.floor(l.left), Math.floor(l.top), Math.ceil(l.right), Math.ceil(l.bottom)];
      if (box[2] <= box[0]) box[2] = box[0] + 1;
      if (box[3] <= box[1]) box[3] = box[1] + 1;
      return { text: l.text.slice(0, 500), bounds: box };
    });
    return { labels, warnings: [] };
  } finally { doc.destroy(); }
}
