// Node tests for web/js/storage.js and web/js/files.js (not deployed).
//
//   node --test web/test/
//
// Optional environment:
//   FAKE_INDEXEDDB    path to fake-indexeddb's auto/index.mjs: also runs the IndexedDB tests
//   ANDROID_ARCHIVES  folder of Android-made backups (*.zip, *.ototori) the web must accept
//   JS_ARCHIVE_OUT    folder to write web-made archives into (for the Kotlin reader to check)
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { zipSync } from '../vendor/fflate/browser.js';
import * as files from '../js/files.js';
import * as storage from '../js/storage.js';

const fakeIdb = process.env.FAKE_INDEXEDDB;
if (fakeIdb) await import(pathToFileURL(fakeIdb).href);

const digest = (bytes) => storage.sha256Hex(bytes);
const enc = new TextEncoder();

function page({ x = 412 } = {}) {
  return {
    staves: [{
      lines: [100, 110.5, 121, 131.5, 142], left: 10, right: 1900,
      profile: [[10, 0], [955.5, 0.25]],
      crop: [1, 2, 100, 200], reachedEos: true,
      symbols: [['note_quarter', 'C4', '.', '.', '.', '.'], ['note_4', 'C4', '.', 'upper', '.', '.', x]],
    }],
    warnings: ['原認識結果'], width: 1920, height: 2000,
    systems: [{ staves: [0], has_brace: false }],
    layout: { version: 3, dropped_staves: [], line_ink: [1, 0.5] },
    places: [[null, [412, null, 1, true]]],
    timing: { total: 1234 },
  };
}

const project = (hash) => JSON.stringify({ title: 'テスト 曲', staves: [{ id: 's', name: 'Sop', measures: [{}, {}] }],
  meta: hash ? { source_hash: hash } : {} });

/** A ZIP laid out like ProjectArchive.write, with a hand-written manifest (for rejection cases). */
function archive({ names = ['project.json'], declaredSize = 2, hash, payload = enc.encode('{}'), extra = null,
  namespace = storage.NAMESPACE } = {}) {
  const props = [['format', 'choir-omr-project'], ['version', '1'], ['recognition_namespace', namespace], ['count', String(names.length)]];
  names.forEach((name, i) => props.push([`entry.${i}.name`, name], [`entry.${i}.bytes`, String(declaredSize)], [`entry.${i}.sha256`, hash]));
  const zip = { 'manifest.properties': files.storeProperties(props) };
  for (const name of new Set(names)) zip[name] = payload;
  if (extra) zip[extra] = payload;
  return zipSync(zip);
}

test('StandardMessageCodec matches the Java encoder for known bytes', () => {
  // {"a": 1, "b": 2.0 (double), "c": "é", "d": [true, null], "e": 2^40}
  const bytes = files.encodeMessage({ a: 1, b: new files.Float64(2), c: 'é', d: [true, null], e: 2 ** 40 });
  const expected = [13, 5,
    7, 1, 97, 3, 1, 0, 0, 0,
    7, 1, 98, 6, 0, 0, /* pad to offset 16 */ 0, 0, 0, 0, 0, 0, 0, 0x40, // 2.0 LE
    7, 1, 99, 7, 2, 0xc3, 0xa9,
    7, 1, 100, 12, 2, 1, 0,
    7, 1, 101, 4, 0, 0, 0, 0, 0, 1, 0, 0];
  assert.deepEqual([...bytes], expected);
  assert.deepEqual(files.decodeMessage(bytes), { a: 1, b: 2, c: 'é', d: [true, null], e: 2 ** 40 });
  // Sizes 254..65535 use the 0xFE prefix, larger ones 0xFF.
  const long = 'x'.repeat(300);
  const encoded = files.encodeMessage(long);
  assert.deepEqual([...encoded.subarray(0, 4)], [7, 254, 44, 1]);
  assert.equal(files.decodeMessage(encoded), long);
  assert.equal(files.decodeMessage(files.encodeMessage('y'.repeat(70000))).length, 70000);
  assert.throws(() => files.decodeMessage(new Uint8Array([12, 5, 1])));
});

test('recognition pages keep the attention x a double and validate like RecognitionCache', () => {
  const data = page({ x: 412 });
  const bytes = files.encodeRecognition(data);
  const back = files.decodeRecognition(bytes);
  assert.deepEqual(back, data);
  // The 7th symbol token is written with the DOUBLE tag (6) even though 412 is integral.
  const marker = enc.encode('upper');
  let at = -1;
  for (let i = 0; i < bytes.length && at < 0; i++) if (marker.every((b, j) => bytes[i + j] === b)) at = i;
  let p = at + marker.length;
  for (let k = 0; k < 2; k++) { assert.equal(bytes[p], 7); p += 2 + bytes[p + 1] - 0; } // ".", "."
  assert.equal(bytes[p], 6);
  for (const bad of [{ ...data, width: 1000 }, { ...data, warnings: [1] }, { ...data, height: undefined },
    { ...data, staves: [{ ...data.staves[0], crop: [1, 2, 100, 3000] }] },
    { ...data, staves: [{ ...data.staves[0], symbols: [['bad']] }] },
    { ...data, staves: [{ ...data.staves[0], symbols: [['a', 'b', 'c', 'd', 'e', 'f', NaN]] }] },
    { ...data, staves: [{ ...data.staves[0], symbols: [['a', 'b', 'c', 'd', 'e', 'f', '412']] }] }]) {
    assert.throws(() => storage.validateRecognition(bad));
  }
  storage.validateRecognition({ ...data, staves: [] });
});

test('Properties text round-trips with Java escapes, comments and continuations', () => {
  const stored = files.storeProperties([['entry.0.name', 'a=b:c #!'], ['key with space', ' lead']], 'Mon Nov 17');
  const text = new TextDecoder('latin1').decode(stored);
  assert.match(text, /^#Mon Nov 17\n/);
  assert.match(text, /entry\.0\.name=a\\=b\\:c \\#\\!/);
  const loaded = files.loadProperties(stored);
  assert.equal(loaded.get('entry.0.name'), 'a=b:c #!');
  assert.equal(loaded.get('key with space'), ' lead');
  const java = files.loadProperties(enc.encode('# c\n! c\n  a : 1\nb\t2\nc=line\\\n   continued\nd=\\u00e9\n'));
  assert.deepEqual(Object.fromEntries(java), { a: '1', b: '2', c: 'linecontinued', d: 'é' });
});

test('archives round-trip score, PDF and raw symbols without changing bytes', async () => {
  const entries = ['project.json', 'source.pdf', 'recognition/300/0.bin'].map((name, index) =>
    [name, Uint8Array.from({ length: 140000 + index }, (_, i) => i % 251)]);
  const zip = await files.writeArchive(entries);
  const restored = await files.readArchive(zip);
  assert.deepEqual([...restored.keys()], entries.map(([n]) => n));
  for (const [name, bytes] of entries) assert.deepEqual(restored.get(name).bytes, bytes);
});

test('archives reject traversal, duplicates, unexpected entries, corrupt and oversized payloads', async () => {
  const hash = await digest(enc.encode('{}'));
  for (const name of ['../outside', '/absolute', 'C:/outside', 'recognition/300/../a.bin', 'recognition/300/00.bin']) {
    await assert.rejects(files.readArchive(archive({ names: ['project.json', name], hash })));
  }
  await assert.rejects(files.readArchive(archive({ names: ['project.json', 'project.json'], hash })));
  await assert.rejects(files.readArchive(archive({ extra: 'source.pdf', hash })));
  for (const bytes of [archive({ hash: '0'.repeat(64) }), archive({ declaredSize: 1, hash }),
    archive({ declaredSize: 10_000_001, hash }), archive({ names: ['source.pdf'], hash })]) {
    await assert.rejects(files.readArchive(bytes));
  }
  const onlyManifest = zipSync({ 'manifest.properties': enc.encode(
    `format=choir-omr-project\nversion=1\ncount=1\nentry.0.name=project.json\nentry.0.bytes=2\nentry.0.sha256=${hash}\n`) });
  await assert.rejects(files.readArchive(onlyManifest), /欠けています/);
  await assert.rejects(files.readArchive(archive({ names: ['project.json', 'recognition/300/0.bin'], hash, namespace: 'different-pipeline' })),
    /処理バージョン/);
  // A deflate bomb stops at the declared size.
  const bomb = archive({ hash, payload: new Uint8Array(5_000_000) });
  await assert.rejects(files.readArchive(bomb), /大きすぎます/);
  assert.ok(await files.readArchive(archive({ hash })));
});

test('staging checks the score against its PDF and recognition', async () => {
  const pdf = enc.encode('%PDF-1.4 fake');
  const hash = await digest(pdf);
  const good = await files.writeArchive([['project.json', enc.encode(project(hash))], ['source.pdf', pdf],
    ['recognition/300/0.bin', files.encodeRecognition(page())]]);
  const staged = await files.inspectArchive(good);
  assert.equal(staged.hash, hash);
  assert.equal(staged.recognition.length, 1);
  assert.deepEqual(staged.recognition[0].data, page());
  const otherPdf = await files.writeArchive([['project.json', enc.encode(project(hash))], ['source.pdf', enc.encode('other')]]);
  await assert.rejects(files.inspectArchive(otherPdf), /ハッシュが一致しません/);
  const noPdf = await files.writeArchive([['project.json', enc.encode(project(null))], ['recognition/300/0.bin', files.encodeRecognition(page())]]);
  await assert.rejects(files.inspectArchive(noPdf));
  const badPage = await files.writeArchive([['project.json', enc.encode(project(hash))], ['source.pdf', pdf],
    ['recognition/300/0.bin', files.encodeMessage({ width: 1920 })]]);
  await assert.rejects(files.inspectArchive(badPage));
  const noStaves = await files.writeArchive([['project.json', enc.encode('{"staves":[]}')]]);
  await assert.rejects(files.inspectArchive(noStaves));
});

test('file names follow Android', () => {
  assert.equal(files.shareName('春 の/歌:*?'), '春_の_歌');
  assert.equal(files.shareName('全角\u3000空白'), '全角\u3000空白'); // Java \s is ASCII only
  assert.equal(files.shareName('///'), '音鳥の曲');
  assert.equal(files.shareName('a'.repeat(80)).length, 60);
  assert.equal(files.exportName('midi', 'Soprano_part-1.mid'), 'Soprano_part-1.mid');
  assert.equal(files.exportName('midi', '../x.mid'), 'choir-score.mid');
  assert.equal(files.exportName('musicxml', 'x'), 'choir-score.musicxml');
  assert.equal(files.exportName('json'), 'score-edited.json');
});

test('Android-made archives are accepted', { skip: !process.env.ANDROID_ARCHIVES }, async () => {
  const dir = process.env.ANDROID_ARCHIVES;
  const names = fs.readdirSync(dir).filter((n) => /\.(zip|ototori)$/.test(n));
  assert.ok(names.length > 0, 'no archives found');
  for (const name of names) {
    const staged = await files.inspectArchive(fs.readFileSync(path.join(dir, name)));
    console.log(`${name}: source ${staged.hash ?? 'none'}, ${staged.recognition.length} recognition pages`);
    for (const { data } of staged.recognition) {
      // Re-encoding the decoded page gives the Android bytes back when the types survive.
      storage.validateRecognition(data);
    }
  }
  const bin = path.join(dir, 'android-page.bin');
  if (fs.existsSync(bin)) {
    // A page written by RecognitionCache (Long, Double, nested lists and maps).
    const data = files.decodeRecognition(fs.readFileSync(bin));
    assert.equal(data.staves[0].symbols[1][6], 412);
    assert.equal(data.big, 5_000_000_000);
    assert.deepEqual(data.places[0][1], [412, null, 1, true]);
    assert.deepEqual(files.decodeRecognition(files.encodeRecognition(data)), data);
  }
});

test('writes web-made archives for the Kotlin reader', { skip: !process.env.JS_ARCHIVE_OUT }, async () => {
  const dir = process.env.JS_ARCHIVE_OUT;
  fs.mkdirSync(dir, { recursive: true });
  const pdf = enc.encode('%PDF-1.4 web fixture');
  const hash = await digest(pdf);
  const big = Uint8Array.from({ length: 300000 }, (_, i) => (i * 7) % 256);
  const recognition = [];
  for (let p = 0; p < 12; p++) recognition.push([`recognition/${p % 2 ? 400 : 300}/${p}.bin`, files.encodeRecognition(page({ x: p % 3 ? 412.5 : 412 }))]);
  fs.writeFileSync(path.join(dir, 'web-full.ototori'), await files.writeArchive([['project.json', enc.encode(project(hash))],
    ['source.pdf', pdf], ...recognition]));
  fs.writeFileSync(path.join(dir, 'web-plain.zip'), await files.writeArchive([['project.json', enc.encode(project(null))]]));
  fs.writeFileSync(path.join(dir, 'web-bigpdf.zip'), await files.writeArchive([['project.json', enc.encode(project(await digest(big)))], ['source.pdf', big]]));
  fs.writeFileSync(path.join(dir, 'web-hash.txt'), hash);
});

// ---------------------------------------------------------------- IndexedDB (fake-indexeddb)

test('IndexedDB stores', { skip: !fakeIdb }, async (t) => {
  await t.test('projects', async () => {
    await assert.rejects(storage.saveProject(null, '{"staves":[]}'));
    await assert.rejects(storage.saveProject('bad', project(null)), /Invalid project id/);
    await assert.rejects(storage.saveProject(null, '{"staves":[{}],"x":"' + 'a'.repeat(10_000_000) + '"}'), /too large/);
    const id = await storage.saveProject(null, project(null));
    assert.match(id, /^[0-9a-f-]{36}$/);
    await new Promise((r) => setTimeout(r, 5));
    const second = await storage.saveProject(null, JSON.stringify({ title: '  ', staves: [{ role: 'piano_rh' }, { id: 'A' }],
      meta: { source_hash: 'f'.repeat(64) }, warnings: [1, 2], _choir_mobile_document: { document_id: 'doc' } }));
    const rows = await storage.listProjects();
    assert.deepEqual(rows.map((r) => r.id), [second, id]);
    assert.deepEqual({ ...rows[0], updated: 0, id: '' }, { id: '', title: '無題の楽譜', updated: 0, parts: ['A'], piano: true, measures: 0,
      hasSource: true, documentId: 'doc', warnings: 2 });
    assert.equal(rows[1].title, 'テスト 曲');
    assert.deepEqual(rows[1].parts, ['Sop']);
    assert.equal(rows[1].measures, 2);
    assert.equal(await storage.loadProject(id), JSON.stringify(JSON.parse(project(null))));
    assert.equal(await storage.saveProject(id, project(null)), id);
    assert.equal(await storage.deleteProject(id), true);
    assert.equal(await storage.deleteProject(id), false);
    await assert.rejects(storage.loadProject(id));
  });
  await t.test('settings', async () => {
    assert.equal(await storage.loadAppSettings(), null);
    await assert.rejects(storage.saveAppSettings('[]'));
    await assert.rejects(storage.saveAppSettings(JSON.stringify({ a: 'x'.repeat(10000) })), /too large/);
    await storage.saveAppSettings('{"theme":"dark"}');
    assert.equal(await storage.loadAppSettings(), '{"theme":"dark"}');
  });
  await t.test('conversions', async () => {
    const settings = { source_hash: 'a'.repeat(64), name: 'P.pdf', dpi: 300, pages: 3 };
    const job = (s = settings, extra = {}) => JSON.stringify({ version: 1, settings: s, status: 'waiting', completed_pages: [], error: null, ...extra });
    await assert.rejects(storage.saveConversion(null, job({ ...settings, dpi: 200 })));
    await assert.rejects(storage.saveConversion(null, job({ ...settings, source_hash: 'x' })));
    await assert.rejects(storage.saveConversion(null, job({ ...settings, pages: 0 })));
    await assert.rejects(storage.saveConversion(null, job(settings, { pad: 'x'.repeat(100000) })));
    const id = await storage.saveConversion(null, job());
    await assert.rejects(storage.saveConversion(id, job({ ...settings, dpi: 400 })), /設定を変更できません/);
    await assert.rejects(storage.saveConversion(crypto.randomUUID(), job()));
    assert.equal(await storage.saveConversion(id, job(settings, { status: 'running', completed_pages: [0] })), id);
    const saved = JSON.parse(await storage.loadConversion(id));
    assert.equal(saved.status, 'running');
    assert.equal(typeof saved.updated, 'number');
    const [row] = await storage.listConversions();
    assert.deepEqual({ ...row, updated: 0 }, { id, name: 'P.pdf', status: 'running', completed: 1, updated: 0 });
    await storage.deleteConversion(id);
    assert.deepEqual(await storage.listConversions(), []);
  });
  await t.test('PDFs and recognition', async () => {
    const pdf = enc.encode('%PDF-1.4 stored');
    const hash = await storage.importPdf(pdf);
    assert.equal(hash, await digest(pdf));
    assert.equal(await storage.importPdf(pdf), hash);
    assert.deepEqual(await storage.pdfBytes(hash), pdf);
    assert.equal(await storage.hasPdf(hash), true);
    assert.equal(await storage.pdfBytes('b'.repeat(64)), null);
    await assert.rejects(storage.pdfBytes('nope'), /Invalid PDF source id/);
    assert.equal(await storage.readRecognition(hash, 0, 300), null);
    await assert.rejects(storage.readRecognition(hash, 0, 200));
    await assert.rejects(storage.writeRecognition(hash, 0, 300, { width: 1920 }));
    await storage.writeRecognition(hash, 2, 300, page());
    await storage.writeRecognition(hash, 10, 300, page({ x: 1.5 }));
    await storage.writeRecognition(hash, 1, 400, page());
    assert.deepEqual(await storage.readRecognition(hash, 2, 300), page());
    assert.deepEqual((await storage.listRecognition(hash, 300)).map((e) => e.page), [2, 10]);
  });
  await t.test('backup prepare, stage and commit', async () => {
    const pdf = enc.encode('%PDF-1.4 stored');
    const hash = await digest(pdf);
    const text = project(hash);
    const zip = await files.prepareArchive(text);
    const entries = await files.readArchive(zip);
    assert.deepEqual([...entries.keys()], ['project.json', 'source.pdf', 'recognition/300/10.bin', 'recognition/300/2.bin', 'recognition/400/1.bin']);
    await assert.rejects(files.prepareArchive(project('c'.repeat(64))), /原譜がありません/);
    const staged = await files.stageArchive(zip);
    assert.equal(staged.text, text);
    files.setPdfPageCounter(async () => 3);
    await assert.rejects(files.commitProjectBackup(staged.token)); // page 10 is outside a 3-page PDF
    files.setPdfPageCounter(async () => 11);
    await files.commitProjectBackup(staged.token);
    await assert.rejects(files.commitProjectBackup(staged.token), /一時データ/);
    await files.discardProjectBackup(staged.token);
    // Restoring into a fresh browser: the PDF and pages come back.
    const other = enc.encode('%PDF-1.4 other device');
    const otherHash = await digest(other);
    const fromAndroid = await files.writeArchive([['project.json', enc.encode(project(otherHash))], ['source.pdf', other],
      ['recognition/400/0.bin', files.encodeRecognition(page())]]);
    const second = await files.stageArchive(fromAndroid);
    await files.commitProjectBackup(second.token);
    assert.deepEqual(await storage.pdfBytes(otherHash), other);
    assert.deepEqual(await storage.readRecognition(otherHash, 0, 400), page());
    // Song files received in the browser are handed over once.
    await files.receiveSongFile({ size: fromAndroid.length, arrayBuffer: async () => fromAndroid.slice().buffer });
    const incoming = await files.takeIncomingProject();
    assert.equal(incoming.text, project(otherHash));
    assert.equal(await files.takeIncomingProject(), null);
    await files.receiveSongFile({ size: 3, arrayBuffer: async () => new Uint8Array([1, 2, 3]).buffer });
    assert.match((await files.takeIncomingProject()).error, /^音鳥の曲ファイルとして開けませんでした/);
  });
});
