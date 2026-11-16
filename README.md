# 音鳥（ototori）Web 版

合唱の楽譜PDFを読み取り、パートごとに聴ける音取り音源を作るアプリ「音鳥」のブラウザ版です。画面は Android 版と同じ Flutter のコードで、iPhone の Safari でも動きます。

**https://takeruhitomi.github.io/ototori-web/**

- PDFの読み取り（全ページ、パート構成の自動判定、途中から加わるパート、タイ・テンポなど）は、すべて端末のブラウザの中で行います。PDFはどこにも送信しません。
- 読み取りモデル（約150 MB）は、最初に変換するときに一度だけダウンロードし、端末に保存します。
- 練習（パート別の再生、ミキサー、ループ、テンポ）、小節の修正、ライブラリ、MIDI・MusicXMLの書き出し、曲ファイル（`.ototori`）の共有・取り込みができます。Android 版と曲ファイル・バックアップをやり取りできます。

## Android 版との違い

- 変換中は画面を開いたままにしてください。Android のように裏で変換を続けられません。途中で止まった場合は、読み取り済みのページから再開できます。
- パート名とテンポの文字は、PDFに文字情報があるときだけ読み取ります（Android は文字認識を使います）。スキャンしたPDFでは、パート名は配置から推定し、テンポは ♩=80 から始まります。
- 1ページの読み取りにかかる時間は、iPhone 16 Pro で約30秒です。

## 構成

- `docs/`：公開しているサイト（`flutter build web` の出力と認識モデル）。GitHub Pages はここを配信します。
- `app/`：アプリのソース（Flutter）。ブラウザ用の処理は `app/web/js/` にあり、Android 版の Kotlin（`app/android/`）を移植したものです。Dart 側は `app/lib/web_bridge.dart` で、Android と同じ呼び出しをブラウザの処理へ渡します。

## ライセンス

AGPL-3.0（`LICENSE`）。

- 楽譜認識は [homr](https://github.com/liebharc/homr) 0.7（© Christian Liebhardt ほか、AGPL-3.0）のモデルと手順を使っています。
- ONNX Runtime Web（MIT）、pdf.js（Apache-2.0）、fflate（MIT）を同梱しています。
- ピアノ音源は Salamander Grand Piano（Alexander Holm、CC BY 3.0）の一部を変換したものです。
