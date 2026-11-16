/*
 * Image adapters for the homr 0.7.0 protocol, ported from the 音鳥 Android
 * app (StaffCanvas.kt). ES module used by the recognition worker.
 * homr is Copyright (c) Christian Liebhardt and contributors, AGPL-3.0.
 */
import { staffOffsetAt, staffBent } from './omr-geometry.js';

/** OpenCV createCLAHE(clipLimit, 8x8 tiles).apply for 8-bit grayscale. */
function clahe(gray, width, height, clipLimit = 1.0, tilesX = 8, tilesY = 8) {
  const histSize = 256;
  // OpenCV pads both axes (reflect-101) unless both divide evenly.
  let ext = gray, extW = width, extH = height;
  if (width % tilesX !== 0 || height % tilesY !== 0) {
    extW = width + (tilesX - (width % tilesX));
    extH = height + (tilesY - (height % tilesY));
    ext = new Uint8Array(extW * extH);
    const reflect = (i, n) => (i < n ? i : 2 * n - 2 - i);
    for (let y = 0; y < extH; y++) {
      const sy = reflect(y, height) * width;
      const row = y * extW;
      for (let x = 0; x < extW; x++) ext[row + x] = gray[sy + reflect(x, width)];
    }
  }
  const tileW = extW / tilesX, tileH = extH / tilesY;
  const tileTotal = tileW * tileH;
  const lutScale = Math.fround((histSize - 1) / tileTotal);
  let clip = 0;
  if (clipLimit > 0) clip = Math.max(Math.trunc(clipLimit * tileTotal / histSize), 1);
  const luts = new Uint8Array(tilesX * tilesY * histSize);
  const hist = new Int32Array(histSize);
  for (let ty = 0; ty < tilesY; ty++) {
    for (let tx = 0; tx < tilesX; tx++) {
      hist.fill(0);
      for (let y = ty * tileH; y < (ty + 1) * tileH; y++) {
        const row = y * extW;
        for (let x = tx * tileW; x < (tx + 1) * tileW; x++) hist[ext[row + x]]++;
      }
      if (clip > 0) {
        let clipped = 0;
        for (let i = 0; i < histSize; i++) if (hist[i] > clip) { clipped += hist[i] - clip; hist[i] = clip; }
        const batch = Math.trunc(clipped / histSize);
        let residual = clipped - batch * histSize;
        for (let i = 0; i < histSize; i++) hist[i] += batch;
        if (residual !== 0) {
          const step = Math.max(Math.trunc(histSize / residual), 1);
          for (let i = 0; i < histSize && residual > 0; i += step, residual--) hist[i]++;
        }
      }
      const base = (ty * tilesX + tx) * histSize;
      let sum = 0;
      for (let i = 0; i < histSize; i++) {
        sum += hist[i];
        luts[base + i] = Math.min(255, Math.max(0, Math.round(Math.fround(sum * lutScale))));
      }
    }
  }
  const out = new Uint8Array(width * height);
  const invTw = Math.fround(1 / tileW), invTh = Math.fround(1 / tileH);
  const ind1 = new Int32Array(width), ind2 = new Int32Array(width), xa = new Float32Array(width);
  for (let x = 0; x < width; x++) {
    const txf = Math.fround(x * invTw - 0.5);
    const tx1 = Math.floor(txf);
    xa[x] = txf - tx1;
    ind1[x] = Math.max(tx1, 0) * histSize;
    ind2[x] = Math.min(tx1 + 1, tilesX - 1) * histSize;
  }
  for (let y = 0; y < height; y++) {
    const tyf = Math.fround(y * invTh - 0.5);
    let ty1 = Math.floor(tyf);
    const ya = tyf - ty1, ya1 = 1 - ya;
    const ty2 = Math.min(ty1 + 1, tilesY - 1);
    ty1 = Math.max(ty1, 0);
    const p1 = ty1 * tilesX * histSize, p2 = ty2 * tilesX * histSize;
    const row = y * width;
    for (let x = 0; x < width; x++) {
      const v = gray[row + x];
      const a = xa[x], a1 = 1 - a;
      const res = (luts[p1 + ind1[x] + v] * a1 + luts[p1 + ind2[x] + v] * a) * ya1 +
                  (luts[p2 + ind1[x] + v] * a1 + luts[p2 + ind2[x] + v] * a) * ya;
      out[row + x] = Math.min(255, Math.max(0, Math.round(res)));
    }
  }
  return out;
}

/** OpenCV INTER_LINEAR resize of an 8-bit crop (pixel-centre mapping). */
function resizeLinear(src, sw, sh, dw, dh) {
  const out = new Uint8Array(dw * dh);
  const scaleX = sw / dw, scaleY = sh / dh;
  const xs0 = new Int32Array(dw), xs1 = new Int32Array(dw), fxs = new Float32Array(dw);
  for (let dx = 0; dx < dw; dx++) {
    let fx = (dx + 0.5) * scaleX - 0.5;
    let sx = Math.floor(fx);
    fx -= sx;
    if (sx < 0) { fx = 0; sx = 0; }
    if (sx >= sw - 1) { fx = 0; sx = sw - 1; }
    xs0[dx] = sx; xs1[dx] = Math.min(sx + 1, sw - 1); fxs[dx] = fx;
  }
  for (let dy = 0; dy < dh; dy++) {
    let fy = (dy + 0.5) * scaleY - 0.5;
    let sy = Math.floor(fy);
    fy -= sy;
    if (sy < 0) { fy = 0; sy = 0; }
    if (sy >= sh - 1) { fy = 0; sy = sh - 1; }
    const r0 = sy * sw, r1 = Math.min(sy + 1, sh - 1) * sw;
    for (let dx = 0; dx < dw; dx++) {
      const fx = fxs[dx];
      const top = src[r0 + xs0[dx]] * (1 - fx) + src[r0 + xs1[dx]] * fx;
      const bottom = src[r1 + xs0[dx]] * (1 - fx) + src[r1 + xs1[dx]] * fx;
      out[dy * dw + dx] = Math.round(top * (1 - fy) + bottom * fy);
    }
  }
  return out;
}

const CANVAS_W = 1280, CANVAS_H = 256;

/** Size of a crop resized into the decoder canvas, keeping its aspect ratio. */
function fittedSize(cropW, cropH) {
  if (cropH / cropW > CANVAS_H / CANVAS_W) return [Math.max(1, Math.trunc(cropW / cropH * CANVAS_H)), CANVAS_H];
  return [CANVAS_W, Math.max(1, Math.trunc(cropH / cropW * CANVAS_W))];
}

/** Canvas x -> page x, one decimal. */
function pageX(rect, canvasX) {
  const [fw] = fittedSize(rect.right - rect.left, rect.bottom - rect.top);
  return Math.round((rect.left + canvasX * (rect.right - rect.left) / fw) * 10) / 10;
}

function crop(gray, width, rect) {
  const w = rect.right - rect.left, h = rect.bottom - rect.top;
  const out = new Uint8Array(w * h);
  for (let y = 0; y < h; y++) out.set(gray.subarray((rect.top + y) * width + rect.left, (rect.top + y) * width + rect.right), y * w);
  return out;
}

/** Resize a crop as homr does and centre it vertically on white (1280 x 256). */
function canvasOf(pixels, w, h) {
  const [fw, fh] = fittedSize(w, h);
  const resized = resizeLinear(pixels, w, h, fw, fh);
  const target = new Uint8Array(CANVAS_W * CANVAS_H).fill(255);
  const y0 = Math.trunc((CANVAS_H - fh) / 2);
  for (let y = 0; y < fh; y++) target.set(resized.subarray(y * fw, y * fw + fw), (y0 + y) * CANVAS_W);
  return target;
}

/** Pixels of rect with each column shifted so the staff runs level. */
function straightCrop(gray, width, height, staff, rect) {
  const w = rect.right - rect.left, h = rect.bottom - rect.top;
  const out = new Uint8Array(w * h);
  for (let dx = 0; dx < w; dx++) {
    const x = rect.left + dx;
    const shift = staffOffsetAt(staff, x + 0.5);
    for (let dy = 0; dy < h; dy++) {
      const sy = rect.top + dy + shift;
      const y0 = Math.floor(sy), t = sy - y0;
      const at = (y) => (y >= 0 && y < height ? gray[y * width + x] : 255);
      out[dy * w + dx] = Math.min(255, Math.max(0, Math.round(at(y0) * (1 - t) + at(y0 + 1) * t)));
    }
  }
  return out;
}

function canvasFor(gray, width, height, staff, rect) {
  const w = rect.right - rect.left, h = rect.bottom - rect.top;
  if (!staffBent(staff)) return canvasOf(crop(gray, width, rect), w, h);
  return canvasOf(straightCrop(gray, width, height, staff, rect), w, h);
}

const clampInt = (v, lo, hi) => Math.min(Math.max(v, lo), hi);

/** StaffCanvas.prepare: crop with 2 spaces left/right, 4 above/below (not past neighbours). */
function prepareStaff(gray, width, height, staff, previous, next) {
  const left = clampInt(Math.floor(staff.left - 2 * staff.spacing), 0, width - 1);
  const right = clampInt(Math.ceil(staff.right + 2 * staff.spacing), left + 1, width);
  const topLimit = previous ? previous.lines[previous.lines.length - 1] : 0;
  const bottomLimit = next ? next.lines[0] : height;
  const top = clampInt(Math.floor(Math.max(topLimit, staff.lines[0] - 4 * staff.spacing)), 0, height - 1);
  const bottom = clampInt(Math.ceil(Math.min(bottomLimit, staff.lines[4] + 4 * staff.spacing)), top + 1, height);
  const bounds = { left, top, right, bottom };
  return { pixels: canvasFor(gray, width, height, staff, bounds), bounds };
}

/** Round half to even (C rint / OpenCV cvRound / Python round). */
function rint(v) {
  const r = Math.round(v);
  return r - v === 0.5 && r % 2 !== 0 ? r - 1 : r;
}

/** OpenCV borderInterpolate for BORDER_REFLECT_101 (GaussianBlur's default border). */
function reflect101(p, n) {
  if (n === 1) return 0;
  while (p < 0 || p >= n) p = p < 0 ? -p : 2 * n - 2 - p;
  return p;
}

/**
 * OpenCV's bit-exact 8-bit Gaussian kernel: getGaussianKernelBitExact, then
 * error-diffused to 8 fractional bits (getGaussianKernelFixedPoint_ED); the
 * taps are integers summing to 256.
 */
function gaussianKernelFixed(n, sigma) {
  const half = (n - 1) / 2;
  const scale2X = -0.125 / (sigma * sigma);
  const values = new Float64Array(half);
  let sum = 0;
  for (let i = 0, x = 1 - n; i < half; i++, x += 2) { values[i] = Math.exp((x * x) * scale2X); sum += values[i]; }
  sum = sum * 2 + 1;
  const mul1 = 1 / sum;
  const out = new Int32Array(n);
  let err = 0, total = 0;
  for (let i = 0; i < half; i++) {
    const adj = values[i] * mul1 * 256 + err;
    const v0 = rint(adj);
    err = adj - v0;
    out[i] = out[n - 1 - i] = v0;
    total += v0;
  }
  out[half] = 256 - 2 * total;
  return out;
}

/**
 * cv2.GaussianBlur(src, (0, 0), sigma) for 8-bit input: OpenCV takes the
 * bit-exact fixed-point path (fixedSmoothInvoker<uint8_t, ufixedpoint16>):
 * rows with 8-bit taps (exact), columns with 8-bit taps, then
 * (sum + 2^15) >> 16. Kernel size from sigma: cvRound(sigma * 3 * 2 + 1) | 1.
 */
function gaussianBlur8u(src, width, height, sigma) {
  const n = rint(sigma * 3 * 2 + 1) | 1;
  const k = gaussianKernelFixed(n, sigma);
  const r = (n - 1) >> 1;
  const taps = [];
  for (let j = 1; j <= r; j++) if (k[r - j] !== 0) taps.push(j);
  const centre = k[r];
  // Horizontal pass into 8.8 fixed point (max 255 * 256, fits 16 bits).
  const rowsH = new Uint16Array(width * height);
  const padded = new Int32Array(width + 2 * r);
  for (let y = 0; y < height; y++) {
    const row = y * width;
    for (let p = 0; p < width + 2 * r; p++) padded[p] = src[row + reflect101(p - r, width)];
    for (let x = 0; x < width; x++) {
      const c = x + r;
      let acc = centre * padded[c];
      for (const j of taps) acc += k[r - j] * (padded[c - j] + padded[c + j]);
      rowsH[row + x] = acc;
    }
  }
  // Vertical pass: 16 fractional bits, rounded to 8-bit.
  const out = new Uint8Array(width * height);
  const acc = new Int32Array(width);
  for (let y = 0; y < height; y++) {
    const base = y * width;
    for (let x = 0; x < width; x++) acc[x] = centre * rowsH[base + x];
    for (const j of taps) {
      const kj = k[r - j];
      const a = reflect101(y - j, height) * width, b = reflect101(y + j, height) * width;
      for (let x = 0; x < width; x++) acc[x] += kj * (rowsH[a + x] + rowsH[b + x]);
    }
    for (let x = 0; x < width; x++) { const v = (acc[x] + 32768) >>> 16; out[base + x] = v > 255 ? 255 : v; }
  }
  return out;
}

/** cv2.threshold(..., THRESH_OTSU) threshold for 8-bit (getThreshVal_Otsu). */
function otsuThreshold(src) {
  const hist = new Float64Array(256);
  for (let i = 0; i < src.length; i++) hist[src[i]]++;
  const scale = 1 / src.length;
  let mu = 0;
  for (let i = 0; i < 256; i++) mu += i * hist[i];
  mu *= scale;
  const FLT_EPSILON = 1.1920928955078125e-7;
  let mu1 = 0, q1 = 0, maxSigma = 0, maxVal = 0;
  for (let i = 0; i < 256; i++) {
    const p = hist[i] * scale;
    mu1 *= q1;
    q1 += p;
    const q2 = 1 - q1;
    if (Math.min(q1, q2) < FLT_EPSILON || Math.max(q1, q2) > 1 - FLT_EPSILON) continue;
    mu1 = (mu1 + i * p) / q1;
    const mu2 = (mu - q1 * mu1) / q2;
    const sigma = q1 * q2 * (mu1 - mu2) * (mu1 - mu2);
    if (sigma > maxSigma) { maxSigma = sigma; maxVal = i; }
  }
  return maxVal;
}

/**
 * StaffCanvas.inkMask: binary ink mask (1 = ink) after background
 * flattening and Otsu, as the browser version's `systems.ink_mask`.
 */
function inkMask(gray, width, height) {
  const k = Math.max(31, Math.trunc(Math.min(width, height) / 20) | 1);
  const background = gaussianBlur8u(gray, width, height, k / 3);
  const flat = new Uint8Array(width * height);
  for (let i = 0; i < flat.length; i++) {
    // Core.divide(src32f, max(bg32f, 1), ratio, 255) in float, then
    // convertTo(CV_8U, 1, -0.5): numpy truncation emulated by OpenCV rounding.
    const ratio = Math.fround(gray[i] * 255 / Math.max(background[i], 1));
    const v = rint(Math.fround(ratio - 0.5));
    flat[i] = v < 0 ? 0 : v > 255 ? 255 : v;
  }
  const t = otsuThreshold(flat);
  const mask = new Uint8Array(width * height);
  for (let i = 0; i < mask.length; i++) mask[i] = flat[i] > t ? 0 : 1;  // THRESH_BINARY_INV, maxval 1
  return mask;
}

export { clahe, resizeLinear, fittedSize, pageX, canvasOf, canvasFor, prepareStaff, inkMask, rint };
