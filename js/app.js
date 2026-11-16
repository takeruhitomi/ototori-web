import * as pdfjs from '../vendor/pdfjs/pdf.min.mjs';

pdfjs.GlobalWorkerOptions.workerSrc = new URL('../vendor/pdfjs/pdf.worker.min.mjs', import.meta.url).href;

const $ = (id) => document.getElementById(id);
import * as engine from './omr-engine.js';
let pdf = null, loaded = false, running = false, lastResult = null, pageImage = null, started = 0;

/** Same size rule as the Android app: 300 dpi, at most 3840 px wide (and within iOS canvas limits). */
const DPI = 300, MAX_WIDTH = 3840, MAX_AREA = 16_000_000;

function setProgress(id, done, total, text) {
  const box = $(id);
  box.hidden = false;
  box.querySelector('.bar').style.width = total > 0 ? `${Math.min(100, (100 * done) / total)}%` : '0';
  box.querySelector('.label').textContent = text;
}
function status(id, text, error = false) { const el = $(id); el.textContent = text; el.classList.toggle('error', error); }
const seconds = (ms) => `${(ms / 1000).toFixed(1)} 秒`;
const mb = (b) => `${(b / 1e6).toFixed(0)} MB`;

function updateRun() { $('run').disabled = !(loaded && pdf) || running; }

function showEnv(extra = {}) {
  const items = {
    'ブラウザ': navigator.userAgent,
    'CPUコア': navigator.hardwareConcurrency || '不明',
    'メモリ（目安）': navigator.deviceMemory ? `${navigator.deviceMemory} GB` : '不明',
    ...extra,
  };
  $('env').innerHTML = Object.entries(items).map(([k, v]) => `<dt>${k}</dt><dd>${String(v).replace(/</g, '&lt;')}</dd>`).join('');
}
showEnv();

function onEvent(data) {
  switch (data.type) {
    case 'progress': {
      if (data.stage === 'download') setProgress('load-progress', data.done, data.total, `ダウンロード ${mb(data.done)} / 約${mb(data.total)}`);
      else if (data.stage === 'session') setProgress('load-progress', data.done, data.total, `モデルを準備しています ${data.done} / ${data.total}`);
      else if (data.stage === 'segment') setProgress('run-progress', data.done, data.total, `五線と記号の位置を探しています ${data.done} / ${data.total}`);
      else if (data.stage === 'staff') setProgress('run-progress', data.done, data.total, `五線を読み取っています ${data.done} / ${data.total}（${seconds(performance.now() - started)}）`);
      break;
    }
    case 'loaded': {
      loaded = true;
      const i = data.info;
      setProgress('load-progress', 1, 1, '準備できました');
      status('load-status', `${i.fromCache ? '端末に保存したモデルを使いました' : 'ダウンロードしました'}（取得 ${seconds(i.downloadMs)}、準備 ${seconds(i.sessionMs)}）`);
      showEnv({ 'ONNX Runtime': `${i.ort} / WebAssembly / スレッド ${i.threads}${i.isolated ? '' : '（単一スレッド）'}` });
      $('load').disabled = true;
      updateRun();
      if (autoRun) run();
      break;
    }
    case 'gray': drawPreview(data); break;
    case 'staves': drawStaves(data.staves); break;
    case 'staff': addStaff(data); break;
    case 'done': finish(data.page); break;
    case 'log': status('run-status', data.message); break;
    case 'error': {
      running = false; updateRun();
      const target = loaded ? 'run-status' : 'load-status';
      status(target, `エラー: ${data.message}`, true);
      if (!loaded) $('load').disabled = false;
      break;
    }
  }
}
engine.setListener((data) => onEvent(data));
const fail = (e) => onEvent({ type: 'error', message: (e && e.message) || String(e) });

$('load').addEventListener('click', () => {
  $('load').disabled = true;
  status('load-status', '');
  setProgress('load-progress', 0, 1, '開始しています…');
  engine.load({ threads: Math.min(4, navigator.hardwareConcurrency || 1) }).catch(fail);
});

async function openPdf(data, name) {
  pdf = await pdfjs.getDocument({ data }).promise;
  $('page').max = pdf.numPages;
  $('page-count').textContent = `全${pdf.numPages}ページ`;
  status('run-status', `${name} を開きました。`);
  updateRun();
}

$('pdf').addEventListener('change', async (e) => {
  const file = e.target.files[0];
  if (!file) return;
  try { await openPdf(new Uint8Array(await file.arrayBuffer()), file.name); }
  catch (err) { pdf = null; updateRun(); status('run-status', `PDFを開けませんでした: ${err.message}`, true); }
});

async function renderPage(number) {
  const page = await pdf.getPage(number);
  const base = page.getViewport({ scale: 1 });
  let scale = Math.min(DPI / 72, MAX_WIDTH / base.width);
  if (base.width * base.height * scale * scale > MAX_AREA) scale = Math.sqrt(MAX_AREA / (base.width * base.height));
  const viewport = page.getViewport({ scale });
  const canvas = document.createElement('canvas');
  canvas.width = Math.ceil(viewport.width); canvas.height = Math.ceil(viewport.height);
  const ctx = canvas.getContext('2d', { willReadFrequently: true });
  ctx.fillStyle = '#fff'; ctx.fillRect(0, 0, canvas.width, canvas.height);
  // 'print' renders without requestAnimationFrame, so a hidden tab (another
  // app in front on a phone) does not stall the page.
  await page.render({ canvasContext: ctx, viewport, background: 'rgb(255,255,255)', intent: 'print' }).promise;
  const image = ctx.getImageData(0, 0, canvas.width, canvas.height);
  canvas.width = canvas.height = 0;
  return image;
}

async function run() {
  if (!(loaded && pdf) || running) return;
  const number = Math.min(Math.max(1, parseInt($('page').value, 10) || 1), pdf.numPages);
  running = true; updateRun();
  $('result').hidden = false; $('staves').innerHTML = ''; $('summary').innerHTML = '';
  lastResult = null;
  started = performance.now();
  setProgress('run-progress', 0, 1, 'ページを描画しています…');
  status('run-status', '');
  try {
    const t = performance.now();
    const image = await renderPage(number);
    const renderMs = performance.now() - t;
    lastResult = { page: number, renderMs: Math.round(renderMs), render: [image.width, image.height] };
    await engine.recognize({ rgba: image.data, srcWidth: image.width, srcHeight: image.height });
  } catch (err) {
    fail(err);
  }
}
$('run').addEventListener('click', run);

function drawPreview({ gray, width, height }) {
  const canvas = $('preview');
  canvas.width = width / 2; canvas.height = Math.round(height / 2);
  const ctx = canvas.getContext('2d');
  const img = ctx.createImageData(canvas.width, canvas.height);
  for (let y = 0; y < canvas.height; y++) for (let x = 0; x < canvas.width; x++) {
    const v = gray[(2 * y) * width + 2 * x], p = (y * canvas.width + x) * 4;
    img.data[p] = img.data[p + 1] = img.data[p + 2] = v; img.data[p + 3] = 255;
  }
  ctx.putImageData(img, 0, 0);
  pageImage = img;
}

function drawStaves(staves) {
  const ctx = $('preview').getContext('2d');
  ctx.lineWidth = 2;
  staves.forEach((s, i) => {
    ctx.strokeStyle = 'rgba(47,107,79,.9)';
    ctx.strokeRect(s.left / 2, s.lines[0] / 2 - 2, (s.right - s.left) / 2, (s.lines[4] - s.lines[0]) / 2 + 4);
    ctx.fillStyle = 'rgba(47,107,79,.95)'; ctx.font = 'bold 14px sans-serif';
    ctx.fillText(String(i + 1), Math.max(2, s.left / 2 - 16), s.lines[2] / 2 + 5);
  });
}

function tokenText(symbols) {
  return symbols.map(([r, p, l]) => {
    if (r === 'barline') return '|';
    let t = r.replace('keySignature_', 'key').replace('timeSignature/', 'time/').replace('note_', '♪').replace('rest_', '休');
    if (p && p !== '.' && p !== '_') t += p + (l && l !== '_' && l !== '.' ? l : '');
    return t;
  }).join(' ');
}

function addStaff({ index, staff, encoderMs, decoderMs }) {
  const bars = staff.symbols.filter((s) => s[0] === 'barline').length;
  const notes = staff.symbols.filter((s) => s[0].startsWith('note_')).length;
  const el = document.createElement('details');
  el.innerHTML = `<summary>五線 ${index + 1}: 記号 ${staff.symbols.length}（音符 ${notes}、小節線 ${bars}）・${seconds(encoderMs + decoderMs)}${staff.reachedEos ? '' : ' ・上限で打ち切り'}</summary><p class="tokens"></p>`;
  el.querySelector('.tokens').textContent = tokenText(staff.symbols);
  $('staves').appendChild(el);
}

function finish(page) {
  running = false; updateRun();
  const total = performance.now() - started;
  const t = page.timing;
  setProgress('run-progress', 1, 1, `完了（${seconds(total)}）`);
  const items = {
    'ページ': `${lastResult.page}（描画 ${lastResult.render[0]}×${lastResult.render[1]} px）`,
    '五線': `${page.staves.length} 本`,
    '合計': seconds(total),
    'PDF描画': seconds(lastResult.renderMs),
    '前処理': seconds((t.gray || 0) + (t.clahe || 0)),
    '位置検出': seconds(t.segmentation || 0),
    '五線の読み取り': `${seconds((t.encoder || 0) + (t.decoder || 0))}（1本あたり ${seconds(((t.encoder || 0) + (t.decoder || 0)) / Math.max(1, page.staves.length))}）`,
  };
  $('summary').innerHTML = Object.entries(items).map(([k, v]) => `<dt>${k}</dt><dd>${v}</dd>`).join('');
  Object.assign(lastResult, { totalMs: Math.round(total), timing: t, staves: page.staves, height: page.height, ua: navigator.userAgent });
  window.__otoriResult = lastResult;
}

$('copy').addEventListener('click', async () => {
  if (!lastResult) return;
  const text = JSON.stringify(lastResult);
  try { await navigator.clipboard.writeText(text); $('copy').textContent = 'コピーしました'; }
  catch { status('run-status', 'コピーできませんでした。', true); }
});

// Developer hook: ?pdf=<url>&page=<n> loads the models and reads the page.
const params = new URLSearchParams(location.search);
const autoRun = params.has('pdf');
if (autoRun) {
  $('page').value = params.get('page') || '1';
  fetch(params.get('pdf')).then((r) => r.arrayBuffer()).then((b) => openPdf(new Uint8Array(b), params.get('pdf')))
    .then(() => $('load').click())
    .catch((err) => status('run-status', `PDFを開けませんでした: ${err.message}`, true));
}
