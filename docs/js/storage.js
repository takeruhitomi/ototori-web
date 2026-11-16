/*
 * App-private storage in IndexedDB (Android: ProjectStore.kt, ConversionStore.kt,
 * PdfSourceStore.kt, omr/RecognitionCache.kt and the app settings file of
 * MainActivity.kt). Validation, limits and return shapes follow the Kotlin
 * stores, because the Dart UI casts the values the same way on both.
 *
 * One database "ototori" (version 1):
 *   projects        id -> {id, version: 1, title, updated, summary}   library rows
 *   projectScores   id -> score JSON text (as ProjectStore.load returns it)
 *   settings        "app" -> settings JSON text
 *   conversions     id -> {text, modified}                          job JSON text
 *   pdfs            sha256 hex -> {bytes: ArrayBuffer, size, added}
 *   recognition     [namespace, sha256, dpi, page] -> page symbol data (plain object)
 * Each write is one IndexedDB transaction, so a failure keeps the previous version
 * (AtomicFile on Android).
 */

const DB_NAME = 'ototori';
const DB_VERSION = 1;

/** Same as RecognitionCache.NAMESPACE: bump when the model, crop or decoding pipeline changes. */
export const NAMESPACE = 'symbols-v2-barline-context4-396-308';

export const MAX_SCORE_BYTES = 10_000_000;
export const MAX_CONVERSION_BYTES = 100_000;
export const MAX_SETTINGS_CHARS = 10_000;

const ID = /^[0-9a-f-]{36}$/;
const HASH = /^[0-9a-f]{64}$/;

// ---------------------------------------------------------------- helpers

/** Kotlin's require(): IllegalArgumentException, "Failed requirement." without a message. */
export function require(condition, message = 'Failed requirement.') {
  if (!condition) throw new Error(message);
}

const encoder = new TextEncoder();
export const utf8Length = (text) => encoder.encode(text).length;

/** SHA-256 as lower-case hex (PdfSourceStore / ProjectArchive). */
export async function sha256Hex(bytes) {
  const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', bytes));
  let out = '';
  for (const b of digest) out += b.toString(16).padStart(2, '0');
  return out;
}

const isObject = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);

/** org.json optString: absent/null -> fallback, other values as text. */
function optString(object, key, fallback = '') {
  const v = isObject(object) ? object[key] : undefined;
  if (v === undefined || v === null) return fallback;
  if (typeof v === 'string') return v;
  if (typeof v === 'number' || typeof v === 'boolean') return String(v);
  return JSON.stringify(v);
}
const ifBlank = (text, fallback) => (text.trim() === '' ? fallback : text);

/** JSONObject(text): the text must be a JSON object. */
function parseObject(text) {
  require(typeof text === 'string', 'Failed requirement.');
  const value = JSON.parse(text);
  if (!isObject(value)) throw new Error('Value is not a JSONObject');
  return value;
}

function bytesOf(data) {
  if (data instanceof Uint8Array) return data;
  if (data instanceof ArrayBuffer) return new Uint8Array(data);
  if (ArrayBuffer.isView(data)) return new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
  if (Array.isArray(data)) return Uint8Array.from(data);
  throw new Error('Failed requirement.');
}

// ---------------------------------------------------------------- database

let opening = null;
let persistAsked = false;

function askPersistence() {
  if (persistAsked) return;
  persistAsked = true;
  // Best effort: Safari and Chrome may evict non-persistent site data under pressure.
  try { globalThis.navigator?.storage?.persist?.().catch(() => {}); } catch { /* not available */ }
}

function openDb() {
  if (opening) return opening;
  opening = new Promise((resolve, reject) => {
    let request;
    try { request = indexedDB.open(DB_NAME, DB_VERSION); }
    catch (e) { reject(new Error(`ブラウザの保存領域を開けません: ${e?.message ?? e}`)); return; }
    request.onupgradeneeded = () => {
      const db = request.result;
      for (const name of ['projects', 'projectScores', 'settings', 'conversions', 'pdfs', 'recognition']) {
        if (!db.objectStoreNames.contains(name)) db.createObjectStore(name);
      }
    };
    request.onsuccess = () => {
      const db = request.result;
      // Another tab upgrading the schema: let it proceed; the next call reopens.
      db.onversionchange = () => { db.close(); opening = null; };
      db.onclose = () => { opening = null; };
      resolve(db);
    };
    request.onerror = () => reject(new Error(`ブラウザの保存領域を開けません: ${request.error?.message ?? request.error}`));
    request.onblocked = () => reject(new Error('別のタブが古い版の音鳥を開いています。そのタブを閉じてください。'));
  });
  opening.catch(() => { opening = null; });
  askPersistence();
  return opening;
}

const done = (request) => new Promise((resolve, reject) => {
  request.onsuccess = () => resolve(request.result);
  request.onerror = () => reject(request.error);
});

function storageError(e) {
  if (e?.name === 'QuotaExceededError') return new Error('ブラウザの保存容量が足りません。');
  return e instanceof Error ? e : new Error(e?.message ?? String(e));
}

/**
 * Runs fn(stores) in one transaction and resolves with its result once the
 * transaction has committed. fn may await requests (not other promises).
 */
async function transaction(names, mode, fn) {
  const db = await openDb();
  return new Promise((resolve, reject) => {
    let tx;
    try { tx = db.transaction(names, mode); } catch (e) { reject(storageError(e)); return; }
    const stores = Object.fromEntries(names.map((n) => [n, tx.objectStore(n)]));
    let result, failure = null;
    tx.oncomplete = () => (failure ? reject(failure) : resolve(result));
    tx.onerror = () => reject(storageError(failure ?? tx.error));
    tx.onabort = () => reject(storageError(failure ?? tx.error ?? new Error('保存を中断しました。')));
    let pending;
    try { pending = fn(stores); } catch (e) { pending = Promise.reject(e); }
    Promise.resolve(pending).then((value) => { result = value; }, (e) => {
      failure = e;
      try { tx.abort(); } catch { /* already finished */ }
    });
  });
}

// ---------------------------------------------------------------- projects (ProjectStore.kt)

const projectId = (id) => { require(typeof id === 'string' && ID.test(id), 'Invalid project id'); return id; };

/** Library row summary: sung part names, piano, bar count and whether the PDF is linked. */
export function projectSummary(score) {
  const staves = score?.staves;
  if (!Array.isArray(staves)) return {};
  const parts = [];
  let piano = false, measures = 0;
  for (const staff of staves) {
    if (!isObject(staff)) continue;
    const role = optString(staff, 'role');
    if (role === 'piano_rh' || role === 'piano_lh') piano = true;
    else parts.push(ifBlank(optString(staff, 'name'), optString(staff, 'id')));
    if (Array.isArray(staff.measures)) measures = Math.max(measures, staff.measures.length);
  }
  const meta = isObject(score.meta) ? score.meta : null;
  const hash = meta?.source_hash;
  const document = isObject(score._choir_mobile_document) ? optString(score._choir_mobile_document, 'document_id') : '';
  return {
    parts, piano, measures,
    hasSource: typeof hash === 'string' && hash.length > 0,
    documentId: document,
    warnings: Array.isArray(score.warnings) ? score.warnings.length : 0,
  };
}

export async function listProjects() {
  const rows = await transaction(['projects'], 'readonly', async ({ projects }) => {
    const [keys, values] = await Promise.all([done(projects.getAllKeys()), done(projects.getAll())]);
    return keys.map((id, i) => {
      const v = values[i];
      if (!isObject(v) || typeof v.updated !== 'number') {
        return { id: String(id), title: '読み込めない楽譜（保存データを保持しています）', updated: 0 };
      }
      return { id: String(id), title: ifBlank(String(v.title ?? '楽譜'), '無題の楽譜'), updated: v.updated, ...(v.summary ?? {}) };
    });
  });
  return rows.sort((a, b) => b.updated - a.updated);
}

export async function loadProject(id) {
  projectId(id);
  const [meta, text] = await transaction(['projects', 'projectScores'], 'readonly', ({ projects, projectScores }) =>
    Promise.all([done(projects.get(id)), done(projectScores.get(id))]));
  if (meta === undefined || text === undefined) throw new Error('保存した楽譜が見つかりません。');
  require(meta.version === 1, 'Unsupported project version');
  require(typeof text === 'string', 'Failed requirement.');
  return text;
}

/** Saves a score (new when id is null) and returns its id. */
export async function saveProject(id, text) {
  require(typeof text === 'string', 'Failed requirement.');
  require(utf8Length(text) <= MAX_SCORE_BYTES, 'Score is too large');
  const parsed = parseObject(text);
  require(Array.isArray(parsed.staves), 'JSONObject["staves"] is not a JSONArray.');
  require(parsed.staves.length > 0);
  const key = id ?? crypto.randomUUID();
  projectId(key);
  const meta = {
    id: key, version: 1,
    title: ifBlank(optString(parsed, 'title', '楽譜'), '無題の楽譜'),
    updated: Date.now(),
    summary: projectSummary(parsed),
  };
  // Stored compact, as JSONObject.toString() returns it on Android.
  const score = JSON.stringify(parsed);
  await transaction(['projects', 'projectScores'], 'readwrite', async ({ projects, projectScores }) => {
    await done(projectScores.put(score, key));
    await done(projects.put(meta, key));
  });
  return key;
}

/** True when the project existed. */
export async function deleteProject(id) {
  projectId(id);
  return transaction(['projects', 'projectScores'], 'readwrite', async ({ projects, projectScores }) => {
    const existed = (await done(projects.count(id))) > 0 || (await done(projectScores.count(id))) > 0;
    if (existed) { await done(projects.delete(id)); await done(projectScores.delete(id)); }
    return existed;
  });
}

// ---------------------------------------------------------------- app settings

export async function loadAppSettings() {
  const text = await transaction(['settings'], 'readonly', ({ settings }) => done(settings.get('app')));
  return typeof text === 'string' ? text : null;
}

export async function saveAppSettings(text) {
  require(typeof text === 'string', 'Failed requirement.');
  require(text.length < MAX_SETTINGS_CHARS, 'Settings are too large');
  parseObject(text);
  await transaction(['settings'], 'readwrite', ({ settings }) => done(settings.put(text, 'app')));
  return null;
}

// ---------------------------------------------------------------- conversion jobs (ConversionStore.kt)

const conversionId = (id) => { require(typeof id === 'string' && ID.test(id)); return id; };
const intOf = (v) => {
  // org.json getInt: numbers (truncated) and numeric strings.
  const n = typeof v === 'number' ? v : typeof v === 'string' && v.trim() !== '' ? Number(v) : NaN;
  require(Number.isFinite(n), `Value ${JSON.stringify(v)} is not an int.`);
  return Math.trunc(n);
};

/** Checks a job text as ConversionStore.save does; returns the parsed job. */
export function validateConversion(text) {
  require(typeof text === 'string');
  require(utf8Length(text) <= MAX_CONVERSION_BYTES);
  const data = parseObject(text);
  require(intOf(data.version) === 1);
  const settings = data.settings;
  require(isObject(settings), 'JSONObject["settings"] is not a JSONObject.');
  require(typeof settings.source_hash === 'string' && HASH.test(settings.source_hash));
  require([300, 400].includes(intOf(settings.dpi)));
  require(intOf(settings.pages) > 0);
  return data;
}

export async function saveConversion(id, text) {
  const data = validateConversion(text);
  const key = id ?? crypto.randomUUID();
  conversionId(key);
  return transaction(['conversions'], 'readwrite', async ({ conversions }) => {
    if (id != null) {
      const previous = await done(conversions.get(id));
      if (previous === undefined) throw new Error('変換ジョブが見つかりません。');
      const before = parseObject(previous.text).settings;
      require(JSON.stringify(before) === JSON.stringify(data.settings), '既存ジョブの設定を変更できません。');
    }
    data.updated = Date.now();
    await done(conversions.put({ text: JSON.stringify(data), modified: data.updated }, key));
    return key;
  });
}

export async function loadConversion(id) {
  conversionId(id);
  const record = await transaction(['conversions'], 'readonly', ({ conversions }) => done(conversions.get(id)));
  if (record === undefined) throw new Error('変換ジョブが見つかりません。');
  return record.text;
}

/**
 * Forgets a job (its settings and progress). Recognised pages stay in the
 * recognition cache, keyed by the PDF, so converting it again reuses them.
 */
export async function deleteConversion(id) {
  conversionId(id);
  await transaction(['conversions'], 'readwrite', ({ conversions }) => done(conversions.delete(id)));
  return null;
}

export async function listConversions() {
  const rows = await transaction(['conversions'], 'readonly', async ({ conversions }) => {
    const [keys, values] = await Promise.all([done(conversions.getAllKeys()), done(conversions.getAll())]);
    return keys.map((id, i) => {
      const record = values[i];
      try {
        const data = parseObject(record.text);
        require(isObject(data.settings));
        require(data.status !== undefined && data.status !== null);
        require(Array.isArray(data.completed_pages));
        require(typeof data.updated === 'number');
        return {
          id: String(id), name: optString(data.settings, 'name', 'PDF'), status: String(data.status),
          completed: data.completed_pages.length, updated: Math.trunc(data.updated),
        };
      } catch {
        return { id: String(id), name: '読み込めない変換ジョブ', status: 'failed', completed: 0, updated: record?.modified ?? 0 };
      }
    });
  });
  return rows.sort((a, b) => b.updated - a.updated);
}

// ---------------------------------------------------------------- PDF sources (PdfSourceStore.kt)

const pdfId = (hash) => { require(typeof hash === 'string' && HASH.test(hash), 'Invalid PDF source id'); return hash; };

/** Stores the bytes as imported and returns their SHA-256 (the source id). */
export async function importPdf(data) {
  const bytes = bytesOf(data);
  require(bytes.length > 0, 'PDF にページがありません。');
  const hash = await sha256Hex(bytes);
  // Content-addressed: an existing entry already holds these exact bytes.
  const copy = bytes.slice().buffer;
  await transaction(['pdfs'], 'readwrite', async ({ pdfs }) => {
    if ((await done(pdfs.count(hash))) > 0) return;
    await done(pdfs.put({ bytes: copy, size: copy.byteLength, added: Date.now() }, hash));
  });
  return hash;
}

/** The stored PDF (a new copy each call: pdf.js takes ownership of its buffer), or null. */
export async function pdfBytes(hash) {
  pdfId(hash);
  const record = await transaction(['pdfs'], 'readonly', ({ pdfs }) => done(pdfs.get(hash)));
  if (!record) return null;
  return new Uint8Array(record.bytes);
}

export async function hasPdf(hash) {
  pdfId(hash);
  return (await transaction(['pdfs'], 'readonly', ({ pdfs }) => done(pdfs.count(hash)))) > 0;
}

// ---------------------------------------------------------------- recognition cache (RecognitionCache.kt)

const isInt = (v) => Number.isInteger(v) && v >= -2147483648 && v <= 2147483647;

/** RecognitionCache.validate: the page shape every consumer relies on. Throws when malformed. */
export function validateRecognition(data) {
  require(isObject(data), 'Invalid recognition data');
  const width = data.width, height = data.height;
  require(isInt(width));
  require(width === 1920 && isInt(height) && height >= 1 && height <= 100000);
  const warnings = data.warnings;
  require(Array.isArray(warnings) && warnings.length <= 4096 && warnings.every((w) => typeof w === 'string'));
  const staves = data.staves;
  require(Array.isArray(staves) && staves.length <= 1000);
  for (const staff of staves) {
    require(isObject(staff), 'Invalid staff cache');
    const crop = staff.crop;
    require(Array.isArray(crop), 'Invalid crop');
    require(crop.length === 4 && crop.every(isInt));
    require(crop[0] >= 0 && crop[1] >= 0 && crop[2] <= width && crop[3] <= height && crop[0] < crop[2] && crop[1] < crop[3]);
    require(typeof staff.reachedEos === 'boolean');
    const symbols = staff.symbols;
    require(Array.isArray(symbols), 'Invalid symbols');
    require(symbols.length <= 608 && symbols.every((s) => Array.isArray(s)
      && (s.length === 6 || (s.length === 7 && typeof s[6] === 'number' && Number.isFinite(s[6])))
      && s.slice(0, 6).every((t) => typeof t === 'string' && t.length <= 256)));
  }
  return data;
}

function recognitionKey(hash, page, dpi) {
  require(typeof hash === 'string' && HASH.test(hash) && Number.isInteger(page) && page >= 0 && (dpi === 300 || dpi === 400));
  return [NAMESPACE, hash, dpi, page];
}

/** The cached page, or null (an unreadable entry is dropped, as on Android). */
export async function readRecognition(hash, page, dpi) {
  const key = recognitionKey(hash, page, dpi);
  const data = await transaction(['recognition'], 'readonly', ({ recognition }) => done(recognition.get(key)));
  if (data === undefined) return null;
  try { return validateRecognition(data); }
  catch {
    await transaction(['recognition'], 'readwrite', ({ recognition }) => done(recognition.delete(key))).catch(() => {});
    return null;
  }
}

export async function writeRecognition(hash, page, dpi, data) {
  const key = recognitionKey(hash, page, dpi);
  validateRecognition(data);
  await transaction(['recognition'], 'readwrite', ({ recognition }) => done(recognition.put(data, key)));
  return null;
}

/**
 * Every cached page of a PDF at one dpi, unvalidated, ordered by page:
 * [{page, data}]. Used by the project backup (ProjectBackupStore.prepare).
 */
export async function listRecognition(hash, dpi) {
  require(typeof hash === 'string' && HASH.test(hash) && (dpi === 300 || dpi === 400));
  const range = IDBKeyRange.bound([NAMESPACE, hash, dpi, 0], [NAMESPACE, hash, dpi, Infinity]);
  return transaction(['recognition'], 'readonly', async ({ recognition }) => {
    const [keys, values] = await Promise.all([done(recognition.getAllKeys(range)), done(recognition.getAll(range))]);
    return keys.map((key, i) => ({ page: key[3], data: values[i] }));
  });
}
