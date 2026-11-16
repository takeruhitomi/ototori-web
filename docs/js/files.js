/*
 * File exchange in the browser (Android: the pick / save / backup / share
 * handlers and onActivityResult of MainActivity.kt, ProjectBackupStore.kt
 * and ProjectArchive.kt).
 *
 * Project backups (choir-project.zip) and song files (<title>.ototori) are
 * the same ZIP as on Android, readable in both directions:
 *   manifest.properties     first entry; Java Properties text:
 *                           format=choir-omr-project, version=1,
 *                           recognition_namespace, count,
 *                           entry.<i>.name / .bytes / .sha256
 *   project.json            the project text (<= 10 MB)
 *   source.pdf              the original PDF, when the score has meta.source_hash
 *   recognition/<dpi>/<page>.bin
 *                           raw page symbols in Flutter's StandardMessageCodec
 *                           binary form (RecognitionCache files)
 *
 * Pickers must be opened from a user gesture: every exported picker calls
 * pickFiles() synchronously, before its first await (iOS Safari only opens a
 * file picker within the tap's activation).
 */
import { Inflate, zipSync } from '../vendor/fflate/browser.js';
import * as storage from './storage.js';

const { require, sha256Hex, NAMESPACE, validateRecognition } = storage;

const MAX_EXPORT_BYTES = 10_000_000;
const MAX_SCORE_FILE = 10_000_000;
const HASH = /^[0-9a-f]{64}$/;
const TOKEN = /^[0-9a-f-]{36}$/;

const utf8 = new TextEncoder();
// Kotlin's readText keeps a BOM and replaces malformed bytes; so does this.
const utf8Text = (bytes) => new TextDecoder('utf-8', { ignoreBOM: true }).decode(bytes);

function bytesOf(data) {
  if (data == null) return null;
  if (typeof data === 'string') return utf8.encode(data);
  if (data instanceof Uint8Array) return data;
  if (data instanceof ArrayBuffer) return new Uint8Array(data);
  if (ArrayBuffer.isView(data)) return new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
  if (Array.isArray(data)) return Uint8Array.from(data);
  throw new Error('Failed requirement.');
}

// ====================================================================== StandardMessageCodec
// Flutter's binary message format (io.flutter.plugin.common.StandardMessageCodec),
// little-endian as on Android, so cache pages travel between devices byte-compatible.

/** Marks a number that must be encoded as a double even when it is integral. */
export class Float64 { constructor(value) { this.value = value; } }

const T = { NULL: 0, TRUE: 1, FALSE: 2, INT: 3, LONG: 4, BIGINT: 5, DOUBLE: 6, STRING: 7,
  BYTES: 8, INTS: 9, LONGS: 10, DOUBLES: 11, LIST: 12, MAP: 13, FLOATS: 14 };

class Writer {
  constructor() { this.buffer = new Uint8Array(1024); this.view = new DataView(this.buffer.buffer); this.length = 0; }
  ensure(n) {
    if (this.length + n <= this.buffer.length) return;
    const next = new Uint8Array(Math.max(this.buffer.length * 2, this.length + n));
    next.set(this.buffer.subarray(0, this.length));
    this.buffer = next; this.view = new DataView(next.buffer);
  }
  byte(v) { this.ensure(1); this.buffer[this.length++] = v; }
  bytes(b) { this.ensure(b.length); this.buffer.set(b, this.length); this.length += b.length; }
  align(n) { const mod = this.length % n; if (mod) for (let i = mod; i < n; i++) this.byte(0); }
  u16(v) { this.ensure(2); this.view.setUint16(this.length, v, true); this.length += 2; }
  i32(v) { this.ensure(4); this.view.setInt32(this.length, v, true); this.length += 4; }
  i64(v) { this.ensure(8); this.view.setBigInt64(this.length, BigInt(v), true); this.length += 8; }
  f32(v) { this.ensure(4); this.view.setFloat32(this.length, v, true); this.length += 4; }
  f64(v) { this.ensure(8); this.view.setFloat64(this.length, v, true); this.length += 8; }
  size(n) {
    if (n < 254) this.byte(n);
    else if (n <= 0xffff) { this.byte(254); this.u16(n); }
    else { this.byte(255); this.i32(n); }
  }
  result() { return this.buffer.slice(0, this.length); }
}

function writeValue(w, v) {
  if (v === null || v === undefined) w.byte(T.NULL);
  else if (v === true) w.byte(T.TRUE);
  else if (v === false) w.byte(T.FALSE);
  else if (v instanceof Float64) { w.byte(T.DOUBLE); w.align(8); w.f64(v.value); }
  else if (typeof v === 'number') {
    if (Number.isInteger(v) && v >= -2147483648 && v <= 2147483647) { w.byte(T.INT); w.i32(v); }
    else if (Number.isSafeInteger(v)) { w.byte(T.LONG); w.i64(v); }
    else { w.byte(T.DOUBLE); w.align(8); w.f64(v); }
  } else if (typeof v === 'bigint') {
    if (v >= -(2n ** 63n) && v < 2n ** 63n) { w.byte(T.LONG); w.i64(v); }
    else { w.byte(T.BIGINT); const hex = utf8.encode(v.toString(16)); w.size(hex.length); w.bytes(hex); }
  } else if (typeof v === 'string') { w.byte(T.STRING); const b = utf8.encode(v); w.size(b.length); w.bytes(b); }
  else if (v instanceof Uint8Array) { w.byte(T.BYTES); w.size(v.length); w.bytes(v); }
  else if (v instanceof Int32Array) { w.byte(T.INTS); w.size(v.length); w.align(4); for (const x of v) w.i32(x); }
  else if (v instanceof BigInt64Array) { w.byte(T.LONGS); w.size(v.length); w.align(8); for (const x of v) w.i64(x); }
  else if (v instanceof Float64Array) { w.byte(T.DOUBLES); w.size(v.length); w.align(8); for (const x of v) w.f64(x); }
  else if (v instanceof Float32Array) { w.byte(T.FLOATS); w.size(v.length); w.align(4); for (const x of v) w.f32(x); }
  else if (Array.isArray(v)) { w.byte(T.LIST); w.size(v.length); for (const x of v) writeValue(w, x); }
  else if (v instanceof Map) { w.byte(T.MAP); w.size(v.size); for (const [k, x] of v) { writeValue(w, k); writeValue(w, x); } }
  else if (typeof v === 'object') {
    const entries = Object.entries(v).filter(([, x]) => x !== undefined);
    w.byte(T.MAP); w.size(entries.length);
    for (const [k, x] of entries) { writeValue(w, k); writeValue(w, x); }
  } else throw new Error(`Unsupported value: ${typeof v}`);
}

export function encodeMessage(value) { const w = new Writer(); writeValue(w, value); return w.result(); }

export function decodeMessage(input) {
  const bytes = bytesOf(input);
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let p = 0;
  const need = (n) => { if (p + n > bytes.length) throw new Error('Message corrupted'); };
  const byte = () => { need(1); return bytes[p++]; };
  const align = (n) => { const mod = p % n; if (mod) p += n - mod; };
  const size = () => {
    const b = byte();
    if (b < 254) return b;
    if (b === 254) { need(2); const v = view.getUint16(p, true); p += 2; return v; }
    need(4); const v = view.getInt32(p, true); p += 4;
    if (v < 0) throw new Error('Message corrupted');
    return v;
  };
  const read = () => {
    const type = byte();
    switch (type) {
      case T.NULL: return null;
      case T.TRUE: return true;
      case T.FALSE: return false;
      case T.INT: { need(4); const v = view.getInt32(p, true); p += 4; return v; }
      case T.LONG: { need(8); const v = view.getBigInt64(p, true); p += 8; return Number(v); }
      case T.BIGINT: { const n = size(); need(n); const hex = utf8Text(bytes.subarray(p, p + n)); p += n;
        const neg = hex.startsWith('-'); const v = BigInt('0x' + (neg ? hex.slice(1) : hex)); return neg ? -v : v; }
      case T.DOUBLE: { align(8); need(8); const v = view.getFloat64(p, true); p += 8; return v; }
      case T.STRING: { const n = size(); need(n); const s = new TextDecoder().decode(bytes.subarray(p, p + n)); p += n; return s; }
      case T.BYTES: { const n = size(); need(n); const v = bytes.slice(p, p + n); p += n; return v; }
      case T.INTS: { const n = size(); align(4); need(4 * n); const v = new Int32Array(n);
        for (let i = 0; i < n; i++) v[i] = view.getInt32(p + 4 * i, true); p += 4 * n; return v; }
      case T.LONGS: { const n = size(); align(8); need(8 * n); const v = new BigInt64Array(n);
        for (let i = 0; i < n; i++) v[i] = view.getBigInt64(p + 8 * i, true); p += 8 * n; return v; }
      case T.DOUBLES: { const n = size(); align(8); need(8 * n); const v = new Float64Array(n);
        for (let i = 0; i < n; i++) v[i] = view.getFloat64(p + 8 * i, true); p += 8 * n; return v; }
      case T.FLOATS: { const n = size(); align(4); need(4 * n); const v = new Float32Array(n);
        for (let i = 0; i < n; i++) v[i] = view.getFloat32(p + 4 * i, true); p += 4 * n; return v; }
      case T.LIST: { const n = size(); need(n); const v = new Array(n); for (let i = 0; i < n; i++) v[i] = read(); return v; }
      case T.MAP: {
        const n = size(); need(n);
        const pairs = [];
        for (let i = 0; i < n; i++) pairs.push([read(), read()]);
        if (pairs.every(([k]) => typeof k === 'string')) {
          const object = {};
          for (const [k, v] of pairs) Object.defineProperty(object, k, { value: v, enumerable: true, writable: true, configurable: true });
          return object;
        }
        return new Map(pairs);
      }
      default: throw new Error('Message corrupted');
    }
  };
  const value = read();
  if (p !== bytes.length) throw new Error('Message corrupted');
  return value;
}

const f64 = (v) => (typeof v === 'number' ? new Float64(v) : v);
const f64List = (v) => (Array.isArray(v) ? v.map(f64) : v);

/**
 * A cache page as RecognitionCache writes it: the attention x of a symbol,
 * staff lines, bend profile, line ink and token places are doubles; every
 * other integral number is an int. Top-level nulls are left out
 * (RecognitionCache.readExternal rejects them).
 */
export function encodeRecognition(data) {
  validateRecognition(data);
  const page = {};
  for (const [key, value] of Object.entries(data)) {
    if (value === null || value === undefined) continue;
    page[key] = value;
  }
  page.staves = data.staves.map((staff) => {
    const out = { ...staff };
    if (Array.isArray(staff.lines)) out.lines = f64List(staff.lines);
    if (Array.isArray(staff.profile)) out.profile = staff.profile.map(f64List);
    out.symbols = staff.symbols.map((s) => (s.length === 7 ? [...s.slice(0, 6), new Float64(s[6])] : s));
    return out;
  });
  if (data.layout && typeof data.layout === 'object' && Array.isArray(data.layout.line_ink)) {
    page.layout = { ...data.layout, line_ink: f64List(data.layout.line_ink) };
  }
  if (Array.isArray(data.places)) {
    page.places = data.places.map((staff) => (Array.isArray(staff) ? staff.map((place) => (Array.isArray(place)
      ? place.map((v, i) => (i === 3 ? v : f64(v))) : place)) : staff));
  }
  return encodeMessage(page);
}

/** RecognitionCache.readExternal: decode and validate a cache page. */
export function decodeRecognition(bytes) {
  require(bytes.length <= 64 * 1024 * 1024);
  const data = decodeMessage(bytes);
  require(data !== null && typeof data === 'object' && !Array.isArray(data) && !(data instanceof Map), 'Invalid recognition data');
  validateRecognition(data);
  for (const value of Object.values(data)) require(value !== null, 'Required value was null.');
  return data;
}

// ====================================================================== Java Properties

function escapeProperty(text, key) {
  let out = '';
  for (let i = 0; i < text.length; i++) {
    const c = text[i], code = text.charCodeAt(i);
    if (c === ' ') out += i === 0 || key ? '\\ ' : ' ';
    else if (c === '\\') out += '\\\\';
    else if (c === '\t') out += '\\t';
    else if (c === '\n') out += '\\n';
    else if (c === '\r') out += '\\r';
    else if (c === '\f') out += '\\f';
    else if ('=:#!'.includes(c)) out += '\\' + c;
    else if (code < 0x20 || code > 0x7e) out += '\\u' + code.toString(16).toUpperCase().padStart(4, '0');
    else out += c;
  }
  return out;
}

/** Properties.store output (ISO-8859-1 with \u escapes). */
export function storeProperties(entries, comment = new Date().toString()) {
  let text = comment ? `#${comment.replace(/[\r\n]/g, ' ')}\n` : '';
  for (const [k, v] of entries) text += `${escapeProperty(k, true)}=${escapeProperty(v, false)}\n`;
  return Uint8Array.from(text, (c) => c.charCodeAt(0) & 0xff);
}

/** Properties.load(InputStream): ISO-8859-1, comments, continuations, escapes. */
export function loadProperties(bytes) {
  let text = '';
  for (let i = 0; i < bytes.length; i += 8192) text += String.fromCharCode(...bytes.subarray(i, i + 8192));
  const raw = text.split(/\r\n|\r|\n/);
  const logical = [];
  for (let i = 0; i < raw.length; i++) {
    let line = raw[i].replace(/^[ \t\f]+/, '');
    if (line === '' || line[0] === '#' || line[0] === '!') continue;
    // An odd number of trailing backslashes continues the line.
    const trailing = (l) => { let n = 0; for (let j = l.length - 1; j >= 0 && l[j] === '\\'; j--) n++; return n; };
    while (trailing(line) % 2 === 1 && i + 1 < raw.length) {
      line = line.slice(0, -1) + raw[++i].replace(/^[ \t\f]+/, '');
    }
    if (trailing(line) % 2 === 1) line = line.slice(0, -1);
    logical.push(line);
  }
  const unescape = (s) => s.replace(/\\(u([0-9a-fA-F]{4})|.)/g, (_, c, hex) => {
    if (hex) return String.fromCharCode(parseInt(hex, 16));
    return { t: '\t', n: '\n', r: '\r', f: '\f' }[c] ?? c;
  });
  const out = new Map();
  for (const line of logical) {
    let i = 0;
    while (i < line.length) {
      const c = line[i];
      if (c === '\\') { i += 2; continue; }
      if (c === '=' || c === ':' || c === ' ' || c === '\t' || c === '\f') break;
      i++;
    }
    const key = line.slice(0, i);
    let rest = line.slice(i).replace(/^[ \t\f]+/, '');
    if (rest[0] === '=' || rest[0] === ':') rest = rest.slice(1).replace(/^[ \t\f]+/, '');
    out.set(unescape(key), unescape(rest));
  }
  return out;
}

// ====================================================================== ProjectArchive

export const MAX_TOTAL = 1024 * 1024 * 1024;
const MAX_FILES = 2002;
const MAX_MANIFEST = 512000;
const CACHE_NAME = /^recognition\/(300|400)\/(0|[1-9][0-9]{0,5})\.bin$/;
export const allowedEntry = (name) => name === 'project.json' || name === 'source.pdf' || CACHE_NAME.test(name);
const entryLimit = (name) => (name === 'project.json' ? 10_000_000 : name === 'source.pdf' ? MAX_TOTAL : 64 * 1024 * 1024);

/**
 * ProjectArchive.write: manifest first, then the entries in order.
 * entries: [[name, Uint8Array], ...]. Returns the ZIP bytes.
 */
export async function writeArchive(entries) {
  const list = [...entries];
  const names = list.map(([name]) => name);
  require(names.includes('project.json') && list.length <= MAX_FILES && names.every(allowedEntry) && new Set(names).size === names.length);
  const facts = [];
  let total = 0;
  for (const [name, bytes] of list) {
    require(bytes.length <= entryLimit(name), 'バックアップが大きすぎます。');
    total += bytes.length;
    facts.push([name, bytes.length, await sha256Hex(bytes)]);
  }
  require(total <= MAX_TOTAL);
  const properties = [['format', 'choir-omr-project'], ['version', '1'], ['recognition_namespace', NAMESPACE],
    ['count', String(list.length)]];
  facts.forEach(([name, size, hash], i) => {
    properties.push([`entry.${i}.name`, name], [`entry.${i}.bytes`, String(size)], [`entry.${i}.sha256`, hash]);
  });
  const manifest = storeProperties(properties);
  require(manifest.length <= MAX_MANIFEST);
  const files = { 'manifest.properties': [manifest, { level: 6 }] };
  // The PDF is already compressed; storing it saves time on phones.
  for (const [name, bytes] of list) files[name] = [bytes, { level: name === 'source.pdf' ? 0 : 6 }];
  return zipSync(files);
}

/** The central directory of a ZIP: [{name, method, flags, compressedSize, size, offset}]. */
function zipDirectory(bytes) {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let end = -1;
  for (let i = bytes.length - 22; i >= Math.max(0, bytes.length - 22 - 65535); i--) {
    if (view.getUint32(i, true) === 0x06054b50) { end = i; break; }
  }
  require(end >= 0, 'ZIP ファイルではありません。');
  const count = view.getUint16(end + 10, true);
  const cdSize = view.getUint32(end + 12, true);
  const cdOffset = view.getUint32(end + 16, true);
  require(count !== 0xffff && cdOffset !== 0xffffffff && cdOffset + cdSize <= end, 'この ZIP 形式には対応していません。');
  const entries = [];
  let p = cdOffset;
  for (let i = 0; i < count; i++) {
    require(p + 46 <= end && view.getUint32(p, true) === 0x02014b50, 'ZIP が壊れています。');
    const flags = view.getUint16(p + 8, true);
    const nameLength = view.getUint16(p + 28, true), extra = view.getUint16(p + 30, true), comment = view.getUint16(p + 32, true);
    const rawName = bytes.subarray(p + 46, p + 46 + nameLength);
    const name = flags & 0x800 ? new TextDecoder().decode(rawName) : String.fromCharCode(...rawName);
    entries.push({
      name, flags, method: view.getUint16(p + 10, true),
      compressedSize: view.getUint32(p + 20, true), size: view.getUint32(p + 24, true),
      offset: view.getUint32(p + 42, true),
    });
    p += 46 + nameLength + extra + comment;
  }
  return entries;
}

/** Inflates an entry, failing as soon as it grows past maximum (ProjectArchive.copy). */
function entryData(bytes, entry, maximum) {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const at = entry.offset;
  require(at + 30 <= bytes.length && view.getUint32(at, true) === 0x04034b50, 'ZIP が壊れています。');
  require((entry.flags & 1) === 0, '暗号化された ZIP には対応していません。');
  const start = at + 30 + view.getUint16(at + 26, true) + view.getUint16(at + 28, true);
  const end = start + entry.compressedSize;
  require(end <= bytes.length, 'ZIP が壊れています。');
  const data = bytes.subarray(start, end);
  if (entry.method === 0) {
    require(data.length <= maximum, 'バックアップが大きすぎます。');
    return data;
  }
  require(entry.method === 8, 'この ZIP の圧縮形式には対応していません。');
  const chunks = [];
  let total = 0, finished = false;
  const inflater = new Inflate((chunk, final) => {
    total += chunk.length;
    require(total <= maximum, 'バックアップが大きすぎます。');
    if (chunk.length) chunks.push(chunk);
    if (final) finished = true;
  });
  const step = 16384;
  if (!data.length) inflater.push(new Uint8Array(0), true);
  for (let i = 0; i < data.length; i += step) inflater.push(data.subarray(i, i + step), i + step >= data.length);
  require(finished, 'ZIP が壊れています。');
  const out = new Uint8Array(total);
  let o = 0;
  for (const c of chunks) { out.set(c, o); o += c.length; }
  return out;
}

const parseLong = (text) => {
  require(typeof text === 'string' && /^[+-]?[0-9]+$/.test(text), `For input string: "${text}"`);
  return Number(text);
};

/**
 * ProjectArchive.read: checks the manifest, every name, size and SHA-256.
 * Returns Map<name, {bytes, sha256}> in archive order.
 */
export async function readArchive(input) {
  const bytes = bytesOf(input);
  const directory = zipDirectory(bytes);
  require(directory.length > 0, 'バックアップが空です。');
  const first = directory[0];
  require(first.name === 'manifest.properties' && !first.name.endsWith('/'));
  const manifest = loadProperties(entryData(bytes, first, MAX_MANIFEST));
  require(manifest.get('format') === 'choir-omr-project' && manifest.get('version') === '1');
  const count = parseLong(manifest.get('count'));
  require(count >= 1 && count <= MAX_FILES);
  const expected = new Map();
  let total = 0;
  for (let i = 0; i < count; i++) {
    const name = manifest.get(`entry.${i}.name`);
    require(name != null);
    require(allowedEntry(name) && !expected.has(name), 'バックアップ内の名前が不正です。');
    const size = parseLong(manifest.get(`entry.${i}.bytes`));
    const hash = manifest.get(`entry.${i}.sha256`);
    require(hash != null);
    require(size >= 0 && size <= entryLimit(name) && HASH.test(hash));
    total += size; require(total <= MAX_TOTAL);
    expected.set(name, { size, hash });
  }
  require(expected.has('project.json'));
  if ([...expected.keys()].some((n) => n.startsWith('recognition/'))) {
    require(manifest.get('recognition_namespace') === NAMESPACE, '認識結果の処理バージョンが未対応です。');
  }
  const files = new Map();
  for (const entry of directory.slice(1)) {
    const fact = expected.get(entry.name);
    require(fact != null && !entry.name.endsWith('/') && !files.has(entry.name), 'バックアップの項目が不正です。');
    const data = entryData(bytes, entry, fact.size);
    const hash = await sha256Hex(data);
    require(data.length === fact.size && hash === fact.hash, 'バックアップのサイズまたはハッシュが一致しません。');
    files.set(entry.name, { bytes: data, sha256: hash });
  }
  require(files.size === expected.size && [...expected.keys()].every((n) => files.has(n)), 'バックアップの一部が欠けています。');
  return files;
}

// ====================================================================== ProjectBackupStore

/** meta.source_hash of a project text, or null; the score must have staves. */
export function sourceHash(text) {
  const score = JSON.parse(text);
  require(score !== null && typeof score === 'object' && !Array.isArray(score), 'Value is not a JSONObject');
  require(Array.isArray(score.staves), 'JSONObject["staves"] is not a JSONArray.');
  require(score.staves.length > 0);
  const meta = score.meta;
  if (meta === null || typeof meta !== 'object' || Array.isArray(meta)) return null;
  if (!('source_hash' in meta) || meta.source_hash === null) return null;
  const hash = meta.source_hash;
  require(typeof hash === 'string' && HASH.test(hash));
  return hash;
}

/** ProjectBackupStore.prepare: the ZIP bytes for a project text. */
export async function prepareArchive(text) {
  require(typeof text === 'string');
  const project = utf8.encode(text);
  require(project.length <= 10_000_000);
  const entries = [['project.json', project]];
  const hash = sourceHash(text);
  if (hash) {
    const source = await storage.pdfBytes(hash);
    require(source && (await sha256Hex(source)) === hash, '原譜がありません。通常のJSON書き出しを使うか、原譜を取り込んでください。');
    entries.push(['source.pdf', source]);
    for (const dpi of [300, 400]) {
      const pages = (await storage.listRecognition(hash, dpi))
        .filter(({ page }) => Number.isInteger(page) && page >= 0 && page <= 999999)
        .map(({ page, data }) => ({ name: `${page}.bin`, data }))
        .sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
      for (const { name, data } of pages) entries.push([`recognition/${dpi}/${name}`, encodeRecognition(data)]);
    }
  }
  return writeArchive(entries);
}

const staged = new Map(); // token -> {text, hash, source, recognition: [{dpi, page, data}]}

/** Pure part of ProjectBackupStore.stage: reads and checks an archive. */
export async function inspectArchive(bytes) {
  const entries = await readArchive(bytes);
  const text = utf8Text(entries.get('project.json').bytes);
  const hash = sourceHash(text);
  const source = entries.get('source.pdf') ?? null;
  require((hash == null && source == null) || (hash != null && source != null && source.sha256 === hash),
    '楽譜と原譜のハッシュが一致しません。');
  const names = [...entries.keys()].filter((n) => n.startsWith('recognition/'));
  require(hash != null || names.length === 0);
  const recognition = names.map((name) => {
    const [, dpi, page] = CACHE_NAME.exec(name);
    return { dpi: Number(dpi), page: Number(page), data: decodeRecognition(entries.get(name).bytes) };
  });
  return { text, hash, source: source?.bytes ?? null, recognition };
}

/** ProjectBackupStore.stage: {token, text}; the files wait in memory for commit/discard. */
export async function stageArchive(bytes) {
  const value = await inspectArchive(bytes);
  const token = crypto.randomUUID();
  staged.set(token, value);
  return { token, text: value.text };
}

let pageCounter = async (bytes) => {
  const pdfjs = await import('../vendor/pdfjs/pdf.min.mjs');
  if (!pdfjs.GlobalWorkerOptions.workerSrc) {
    pdfjs.GlobalWorkerOptions.workerSrc = new URL('../vendor/pdfjs/pdf.worker.min.mjs', import.meta.url).href;
  }
  const doc = await pdfjs.getDocument({ data: bytes.slice(), isEvalSupported: false }).promise;
  try { return doc.numPages; } finally { doc.destroy(); }
};
/** Tests replace the pdf.js page count. */
export function setPdfPageCounter(fn) { pageCounter = fn; }

/** Publishes a staged backup's PDF and recognition (the project itself is saved by Dart). */
export async function commitProjectBackup(token) {
  require(typeof token === 'string' && TOKEN.test(token));
  const value = staged.get(token);
  if (!value) throw new Error('バックアップの一時データがありません。もう一度選択してください。');
  if (value.hash) {
    const count = await pageCounter(value.source);
    require(count > 0, 'PDF にページがありません。');
    // Validate all pages before publishing even the source PDF.
    for (const { page, data } of value.recognition) { require(page >= 0 && page < count); validateRecognition(data); }
    require((await storage.importPdf(value.source)) === value.hash);
    for (const { dpi, page, data } of value.recognition) {
      if ((await storage.readRecognition(value.hash, page, dpi)) == null) await storage.writeRecognition(value.hash, page, dpi, data);
    }
  }
  staged.delete(token);
  return null;
}

export async function discardProjectBackup(token) {
  require(typeof token === 'string' && TOKEN.test(token));
  staged.delete(token);
  return null;
}

// ====================================================================== pickers

/**
 * Opens the system file picker; resolves with the chosen files, or [] when
 * cancelled. Call it synchronously from a user gesture.
 */
export function pickFiles({ accept = '', multiple = false } = {}) {
  return new Promise((resolve) => {
    const input = document.createElement('input');
    input.type = 'file';
    if (accept) input.accept = accept;
    input.multiple = !!multiple;
    input.setAttribute('aria-hidden', 'true');
    input.tabIndex = -1;
    input.style.cssText = 'position:fixed;left:0;top:0;width:1px;height:1px;opacity:0;pointer-events:none;';
    let settled = false, timer = 0;
    const onFocus = () => {
      // Browsers without the 'cancel' event: the window regains focus when the
      // picker closes. 'change' may follow focus (iCloud downloads on iOS), so wait.
      clearTimeout(timer);
      timer = setTimeout(() => { if (!input.files || input.files.length === 0) finish([]); }, 4000);
    };
    const finish = (files) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      window.removeEventListener('focus', onFocus);
      input.remove();
      resolve(files);
    };
    input.addEventListener('change', () => finish(Array.from(input.files || [])));
    input.addEventListener('cancel', () => finish([]));
    window.addEventListener('focus', onFocus);
    document.body.appendChild(input);
    input.click();
  });
}

/** The 'pick' handler: a score.json as text, or null when cancelled. */
export async function pickScoreJson() {
  const [file] = await pickFiles({ accept: 'application/json,.json' });
  if (!file) return null;
  require(file.size <= MAX_SCORE_FILE, 'ファイルが大きすぎます。');
  const bytes = new Uint8Array(await file.arrayBuffer());
  require(bytes.length <= MAX_SCORE_FILE, 'ファイルが大きすぎます。');
  return utf8Text(bytes);
}

const ARCHIVE_ACCEPT = '.zip,.ototori,application/zip,application/x-zip-compressed,application/octet-stream';

async function readArchiveFile(file) {
  // Size of the largest valid archive plus ZIP overhead; refuse before reading it into memory.
  require(file.size <= MAX_TOTAL + 64 * 1024 * 1024, 'バックアップが大きすぎます。');
  return new Uint8Array(await file.arrayBuffer());
}

const memoryMessage = (e, fallback) => (e instanceof RangeError || /memory|allocation/i.test(String(e?.message)) ? fallback : null);

/** The 'pickProjectBackup' handler: {token, text} staged, or null when cancelled. */
export async function pickProjectBackup() {
  const [file] = await pickFiles({ accept: ARCHIVE_ACCEPT });
  if (!file) return null;
  try { return await stageArchive(await readArchiveFile(file)); }
  catch (e) { throw new Error(memoryMessage(e, 'メモリ不足でバックアップを開けませんでした。') ?? e?.message ?? String(e)); }
}

// ====================================================================== received song files

let incoming = null;       // {token, text}
let incomingError = null;  // message

function notifyIncoming() {
  const notify = globalThis.ototoriNotifyIncoming ?? globalThis.ototoriPlatform?.notifyIncoming;
  try { if (typeof notify === 'function') notify(); } catch (e) { console.error('notifyIncoming', e); }
}

/**
 * Stages a song file (.ototori) the user opened in the browser, as Android's
 * receive() does for a file shared from another app, and tells the app.
 */
export async function receiveSongFile(file) {
  try {
    const value = await stageArchive(await readArchiveFile(file));
    // A newer file replaces one the UI has not taken yet.
    if (incoming) staged.delete(incoming.token);
    incoming = value; incomingError = null;
  } catch (e) {
    incomingError = memoryMessage(e, 'メモリ不足で曲ファイルを開けませんでした。')
      ?? `音鳥の曲ファイルとして開けませんでした（${e?.message ?? e}）。`;
  }
  notifyIncoming();
}

/** Picker entry point for received song files: true when a file was chosen. */
export async function openSongFile() {
  const [file] = await pickFiles({ accept: ARCHIVE_ACCEPT });
  if (!file) return false;
  await receiveSongFile(file);
  return true;
}

/** {token, text}, {error} or null, once. */
export async function takeIncomingProject() {
  const value = incomingError != null ? { error: incomingError } : incoming;
  incoming = null; incomingError = null;
  return value;
}

// ====================================================================== saving and sharing

const isIos = () => {
  const nav = globalThis.navigator;
  if (!nav) return false;
  return /iPad|iPhone|iPod/.test(nav.userAgent) || (nav.platform === 'MacIntel' && nav.maxTouchPoints > 1);
};

function canShareFile(file) {
  try { return typeof navigator.share === 'function' && navigator.canShare?.({ files: [file] }) === true; }
  catch { return false; }
}

function download(file) {
  const url = URL.createObjectURL(file);
  const a = document.createElement('a');
  a.href = url; a.download = file.name; a.rel = 'noopener'; a.style.display = 'none';
  document.body.appendChild(a);
  a.click();
  a.remove();
  // iOS reads the blob after the click returns; keep the URL alive for a while.
  setTimeout(() => URL.revokeObjectURL(url), 60_000);
}

/**
 * Asks for one more tap when the share sheet needs a fresh user gesture
 * (preparing the file outlived the tap's activation). Resolves true when
 * shared, false when dismissed; rejects when sharing itself fails.
 */
function shareAfterTap(data, label) {
  return new Promise((resolve, reject) => {
    const layer = document.createElement('div');
    layer.setAttribute('role', 'dialog');
    layer.style.cssText = 'position:fixed;inset:0;z-index:2147483647;display:flex;align-items:flex-end;justify-content:center;'
      + 'background:rgba(0,0,0,.35);padding:16px;padding-bottom:max(16px,env(safe-area-inset-bottom));font:16px system-ui,-apple-system,sans-serif;';
    const panel = document.createElement('div');
    panel.style.cssText = 'width:100%;max-width:420px;background:#fff;color:#1a1a1a;border-radius:14px;padding:16px;display:grid;gap:10px;';
    const message = document.createElement('div');
    message.textContent = `${label}の準備ができました。`;
    const share = document.createElement('button');
    share.textContent = '共有・保存する';
    share.style.cssText = 'min-height:48px;border:0;border-radius:10px;background:#1f5fbf;color:#fff;font:inherit;font-weight:600;';
    const cancel = document.createElement('button');
    cancel.textContent = 'キャンセル';
    cancel.style.cssText = 'min-height:44px;border:0;border-radius:10px;background:#eee;color:#1a1a1a;font:inherit;';
    panel.append(message, share, cancel);
    layer.append(panel);
    const close = () => layer.remove();
    share.addEventListener('click', () => {
      close();
      // Called inside the click: the share sheet has its user activation.
      navigator.share(data).then(() => resolve(true), (e) => (e?.name === 'AbortError' ? resolve(false) : reject(e)));
    });
    cancel.addEventListener('click', () => { close(); resolve(false); });
    document.body.appendChild(layer);
    share.focus();
  });
}

/**
 * Hands a file to the user: the share sheet (Files, LINE, AirDrop...) when
 * preferred and possible, else a download. Resolves false when the user
 * dismissed the share sheet.
 */
async function deliver(file, { share, title, label }) {
  if (share && canShareFile(file)) {
    const data = title ? { files: [file], title } : { files: [file] };
    const active = navigator.userActivation ? navigator.userActivation.isActive : true;
    try {
      if (active) { await navigator.share(data); return true; }
      return await shareAfterTap(data, label);
    } catch (e) {
      if (e?.name === 'AbortError') return false;
      if (e?.name === 'NotAllowedError') {
        try { return await shareAfterTap(data, label); } catch { /* fall back to a download */ }
      }
    }
  }
  download(file);
  return true;
}

let exporting = false;

async function exclusive(fn) {
  require(!exporting, '書き出すデータが大きすぎるか、保存先を選択中です。');
  exporting = true;
  try { return await fn(); } finally { exporting = false; }
}

/** The file name Android suggests for each export kind. */
export function exportName(kind, name) {
  if (kind === 'midi') return typeof name === 'string' && /^[a-zA-Z0-9_-]+\.mid$/.test(name) ? name : 'choir-score.mid';
  if (kind === 'musicxml') return 'choir-score.musicxml';
  return 'score-edited.json';
}

const EXPORT_TYPES = { json: 'application/json', midi: 'audio/midi', musicxml: 'application/vnd.recordare.musicxml+xml' };

/** The 'save' / 'saveMidi' / 'saveMusicXml' handlers: true when handed over, false when dismissed. */
export async function saveExport(kind, data, name) {
  require(kind in EXPORT_TYPES, `Unknown export kind: ${kind}`);
  const bytes = kind === 'midi' ? (typeof data === 'string' ? null : bytesOf(data)) : (typeof data === 'string' ? utf8.encode(data) : null);
  require(bytes != null && bytes.length <= MAX_EXPORT_BYTES, '書き出すデータが大きすぎるか、保存先を選択中です。');
  return exclusive(() => {
    const file = new File([bytes], exportName(kind, name), { type: EXPORT_TYPES[kind] });
    return deliver(file, { share: isIos(), label: 'ファイル' });
  });
}

/** A file name for a song title: no path or reserved characters (MainActivity.shareName). */
export function shareName(title) {
  const name = String(title ?? '').replace(/[\\/:*?"<>|\t\n\x0B\f\r ]+/g, '_').replace(/^_+|_+$/g, '').slice(0, 60);
  return name || '音鳥の曲';
}

/** The 'exportProjectBackup' handler: choir-project.zip. */
export async function exportProjectBackup(text) {
  require(typeof text === 'string', '保存先を選択中か、楽譜がありません。');
  return exclusive(async () => {
    const archive = await prepareArchive(text);
    const file = new File([archive], 'choir-project.zip', { type: 'application/zip' });
    return deliver(file, { share: isIos(), label: 'バックアップ' });
  });
}

/** The 'shareProject' handler: <title>.ototori through the share sheet, else a download. */
export async function shareProject(text, title) {
  require(typeof text === 'string', '楽譜がありません。');
  return exclusive(async () => {
    const archive = await prepareArchive(text);
    const file = new File([archive], `${shareName(title)}.ototori`, { type: 'application/octet-stream' });
    return deliver(file, { share: true, title: title || undefined, label: '曲ファイル' });
  });
}
