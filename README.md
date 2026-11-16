# 音鳥 Web（試験版）

合唱の楽譜PDFを読み取る「音鳥」のブラウザ版です。いまは試験版で、PDFの1ページを端末のブラウザだけで読み取り、速度と結果を確かめられます。再生や楽譜の組み立てはまだできません。

公開ページ: https://takeruhitomi.github.io/otori-web/

## しくみ

- PDFは [pdf.js](https://mozilla.github.io/pdf.js/) で 300 dpi（幅は最大 3840 px）に描画し、幅 1920 px のグレースケールにします。
- 認識は [homr](https://github.com/liebharc/homr) 0.7 のモデル（五線・記号の位置を求める segnet、五線を記号列に変える encoder / decoder）を [ONNX Runtime Web](https://onnxruntime.ai/) で動かします。前処理・五線の検出・切り出しは、Android 版の音鳥（Kotlin）をそのまま JavaScript に移したものです。
- PDF もモデルも端末の外には送りません。モデル（約150 MB）は初回だけダウンロードし、ブラウザのキャッシュに保存します。
- GitHub Pages は複数スレッドに必要なヘッダーを送れないため、`coi-sw.js`（Service Worker）で付けています。付けられない環境では1スレッドで動きます。

## ローカルで動かす

```
python -m http.server 8000
```

`http://localhost:8000/` を開きます。この方法では複数スレッドになりません。

## ライセンス

このリポジトリは AGPL-3.0 です（`LICENSE`）。

- `models/*.onnx` と `models/vocabulary.json`：homr 0.7 のモデルと語彙。© Christian Liebhardt ほか、AGPL-3.0。https://github.com/liebharc/homr
- `js/omr-*.js`：homr の手順（分割・デコード）を Android 版から移植したもので、AGPL-3.0。
- `vendor/onnxruntime-web/`：ONNX Runtime Web 1.22.0、MIT License（© Microsoft Corporation）。
- `vendor/pdfjs/`：pdf.js 4.10.38、Apache License 2.0（© Mozilla Foundation）。
