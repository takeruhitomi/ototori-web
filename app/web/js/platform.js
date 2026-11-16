/*
 * Browser implementation of the app's platform channels. The Flutter UI
 * calls them through lib/web_bridge.dart exactly as it calls the Android
 * host (MainActivity.kt / ConversionService.kt); this file dispatches each
 * method to the browser modules:
 *   storage.js   projects, settings, conversion jobs, PDF sources, recognition cache (IndexedDB)
 *   files.js     file pickers, downloads, sharing, backups and song files (.ototori ZIP)
 *   audio.js     playback (Web Audio)
 *   conversion.js  recognition jobs and single pages (omr-engine.js: homr on ONNX Runtime Web)
 *   pdf-source.js  PDF rendering (pdf.js)
 * Errors reject with {code, message} like Android's result.error.
 */
import * as storage from './storage.js';
import * as files from './files.js';
import * as audio from './audio.js';
import * as pdfSource from './pdf-source.js';
import * as conversion from './conversion.js';

class PlatformError extends Error {
  constructor(code, message) { super(message); this.code = code; }
}
const fail = (code, message) => { throw new PlatformError(code, message); };
const describe = (e) => (e && e.message) || String(e);

/** Wraps a handler so any failure becomes {code, message} with the Android wording. */
const guarded = (code, prefix, fn) => async (args) => {
  try { return await fn(args || {}); }
  catch (e) {
    if (e instanceof PlatformError) throw e;
    throw new PlatformError(code, prefix ? `${prefix}: ${describe(e)}` : describe(e));
  }
};

const handlers = {
  'jp.choiromr.mobile/incoming': {
    takeIncomingProject: () => files.takeIncomingProject(),
  },
  'jp.choiromr.mobile/omr': {
    readPageLabels: guarded('layout', '声部名を読み取れません', ({ page }) => conversion.readPageLabels(page)),
    // The browser downloads the models on first recognition (conversion.js),
    // so practice-only visits never fetch 150 MB.
    modelsReady: () => true,
    importModels: () => false, // the browser downloads the models itself
    cancel: ({ jobId }) => { conversion.cancel(jobId); return null; },
    recognizePage: guarded('recognition', '認識を完了できません', ({ page, dpi }) => conversion.recognizePage(page, dpi)),
  },
  'jp.choiromr.mobile/score': {
    setGestureExclusion: () => null,
    loadAppSettings: guarded('settings', '設定を保存・読み込みできません', () => storage.loadAppSettings()),
    saveAppSettings: guarded('settings', '設定を保存・読み込みできません', ({ text }) => storage.saveAppSettings(text)),
    exportProjectBackup: guarded('backup', 'バックアップを作成できません', ({ text }) => {
      if (conversion.busy()) fail('backup', '認識が終了してからバックアップしてください。');
      return files.exportProjectBackup(text);
    }),
    shareProject: guarded('share', '共有できません', ({ text, title }) => {
      if (conversion.busy()) fail('share', '認識が終了してから共有してください。');
      return files.shareProject(text, title || '');
    }),
    pickProjectBackup: guarded('backup', 'バックアップを開けません', () => files.pickProjectBackup()),
    commitProjectBackup: guarded('backup', 'バックアップを復元できません', ({ token }) => {
      if (conversion.busy()) fail('backup', '認識が終了してから復元してください。');
      return files.commitProjectBackup(token);
    }),
    discardProjectBackup: guarded('backup', null, ({ token }) => files.discardProjectBackup(token)),
    listProjects: guarded('project', '楽譜の保存・読み込みに失敗しました', () => storage.listProjects()),
    loadProject: guarded('project', '楽譜の保存・読み込みに失敗しました', ({ id }) => storage.loadProject(id)),
    saveProject: guarded('project', '楽譜の保存・読み込みに失敗しました', ({ id, text }) => storage.saveProject(id ?? null, text)),
    deleteProject: guarded('project', '楽譜の保存・読み込みに失敗しました', ({ id }) => storage.deleteProject(id)),
    pick: guarded('open', '楽譜を開けません', () => files.pickScoreJson()),
    save: guarded('save', '保存できません', ({ text, name }) => files.saveExport('json', text, name)),
    saveMidi: guarded('save', '保存できません', ({ bytes, name }) => files.saveExport('midi', bytes, name)),
    saveMusicXml: guarded('save', '保存できません', ({ text, name }) => files.saveExport('musicxml', text, name)),
    playbackStatus: () => audio.playbackStatus(),
    stop: () => { audio.stop(); return null; },
    updateMixer: guarded('audio', 'ミキサー設定が不正です', (args) => { audio.updateMixer(args); return null; }),
    play: guarded('audio', '試聴できません', async (args) => {
      // Playback wins over recognition, as on Android.
      conversion.cancelForPlayback();
      await audio.play(args);
      return null;
    }),
  },
  'jp.choiromr.mobile/pdf': {
    startNativeConversion: guarded('conversion', '変換を開始できません', ({ id }) => conversion.start(id)),
    nativeConversionState: guarded('conversion', null, ({ id }) => conversion.state(id)),
    saveConversion: guarded('conversion', '変換ジョブを保存・読み込みできません', ({ id, text }) => {
      if (id != null && conversion.activeId() === id) fail('conversion', '実行中のジョブは認識処理が更新します。');
      return storage.saveConversion(id ?? null, text);
    }),
    listConversions: guarded('conversion', '変換ジョブを保存・読み込みできません', () => storage.listConversions()),
    loadConversion: guarded('conversion', '変換ジョブを保存・読み込みできません', ({ id }) => storage.loadConversion(id)),
    deleteConversion: guarded('conversion', '変換ジョブを保存・読み込みできません', ({ id }) => {
      if (conversion.activeId() === id) fail('conversion', '実行中の変換は削除できません。');
      return storage.deleteConversion(id).then(() => true);
    }),
    openSourcePdf: guarded('source', '保存した PDF を開けません', ({ hash, pages }) => pdfSource.openSource(hash, pages)),
    renderSourcePage: guarded('source', '原譜を表示できません', ({ hash, page }) => pdfSource.renderSourcePage(hash, page)),
    pickPdfs: guarded('picker', 'ファイル選択を開始できません', () => pdfSource.pickPdfs()),
    pickPdf: guarded('open', 'PDFを開けません', () => pdfSource.pickPdf()),
    renderPage: guarded('render', '描画できません', ({ page, dpi }) => pdfSource.renderPreview(page, dpi)),
  },
};

globalThis.ototoriPlatform = {
  /** Never rejects: {ok: true, value} or {ok: false, code, message} (read by lib/web_bridge.dart). */
  async call(channel, method, args) {
    const handler = handlers[channel]?.[method];
    if (!handler) return { ok: false, code: 'notImplemented', message: `${channel}.${method}` };
    try {
      const value = await handler(args || {});
      return { ok: true, value: value === undefined ? null : value };
    } catch (e) {
      console.error(`${channel}.${method}`, e);
      return { ok: false, code: e instanceof PlatformError ? e.code : 'web', message: describe(e) };
    }
  },
  /** Tells the app a song file is waiting (files.js calls this after staging one). */
  notifyIncoming() { globalThis.ototoriNotifyIncoming?.(); },
};
