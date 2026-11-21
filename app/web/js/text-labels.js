/*
 * Printed text of a page (part names, tempo mark) from the PDF's own text
 * layer, in the shape Android's PageTextReader returns from ML Kit OCR:
 * one entry per text line, boxes in the 1920-px-wide page frame.
 * PDFs exported from notation software have a text layer; scans do not.
 */
import * as pdfjs from '../vendor/pdfjs/pdf.min.mjs';

/*
 * Notation software writes its music font into the text layer too: SMuFL
 * glyphs in the Private Use Area (clefs, noteheads, and the note of a
 * metronome mark). The metronome notes become the characters tempo_marks.dart
 * reads (♩ ♪, U+1D15E half note, "." for the augmentation dot); every other
 * PUA glyph is dropped, so a line holds only real text.
 */
const SMUFL_METRONOME = {
  0xECA2: '\u{1D15D}', 0xECA3: '\u{1D15E}', 0xECA5: '♩', 0xECA7: '♪', 0xECA9: '\u{1D161}', 0xECB7: '.',
};

export function plainText(text) {
  let out = '';
  for (const ch of text) {
    const code = ch.codePointAt(0);
    if (code >= 0xE000 && code <= 0xF8FF) out += SMUFL_METRONOME[code] ?? ' ';
    else out += ch;
  }
  return out.replace(/\s+/g, ' ').trim();
}

export async function textLabels(page) {
  const base = page.getViewport({ scale: 1 });
  const viewport = page.getViewport({ scale: 1920 / Math.max(1, Math.floor(base.width)) });
  const content = await page.getTextContent();
  const runs = [];
  for (const item of content.items) {
    const text = plainText(item.str || '');
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
}
