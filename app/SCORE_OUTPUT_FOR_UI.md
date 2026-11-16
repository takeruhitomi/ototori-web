# 変換結果（score.json）の読み方：UI・エディター向け

Android版の変換（`assembleLikeBrowser`、`lib/browser_assembly.dart`）が返すJSONの説明。
エディターで原譜画像に重ねて表示・編集するための位置情報（2026-11-08追加）を中心にまとめる。
認識側の実装・検証は `ANDROID_BROWSER_COMPARISON.md` を参照。

## 全体

```
{
  "title", "tempo_bpm",            // 4分音符/分。譜面のテンポ表記から（読めなければ80）
  "warnings": [文字列...],          // 利用者向けの注意（原譜と照合すべき箇所など）
  "meta": {...},
  "staves": [ 追加パート(上)..., 声部..., 追加パート(下)..., ピアノ右手, ピアノ左手 ]
}
```

### meta（主なもの）

| キー | 内容 |
|---|---|
| `voice_names` | 声部名（`staves` の声部の順）。例 `["Tenor I・II", "Bass"]` |
| `voice_names_source` | 声部名の根拠。`"labels"`＝譜面の声部名表記（OCR）、`"male-choir"`＝「男声合唱」の表記。キーがなければ音部記号から推定 |
| `ensemble` | `"TTBB"` などの編成。声部名を表記から取った場合は `"custom"` |
| `piano` | ピアノ伴奏の有無 |
| `voice_count` | 主な声部の数（追加パートを含まない） |
| `tempo` | テンポの根拠。`source`：`"ocr"`（譜面の表記）／`"default"`（読めず80）／`"given"`（呼び出し側の指定）。`"ocr"` のときは `printed`（印刷された数）、`unit`（`"quarter"`・`"dotted-quarter"`・`"eighth"`）、`text`（OCRの文字列）、`page`、`unit_from_time_signature`（付点が読めず拍子から判断したらtrue）。`bpm` は常に4分音符換算 |
| `added_parts[]` | 途中から加わるパート（下記）。`id`、`name`、`name_source`（`"labels"`／`"choir"`／`"default"`）、`position`（`"above1"`＝合唱のすぐ上、など）、`systems[]`（現れる段：`page`、`system`、`staff`（段内の五線番号）、`label`） |
| `layout.pages[]` | ページごとに `page`（1始まり）、`width`（常に1920）、`height`、`systems[]` |
| `layout.pages[].systems[]` | 段の矩形 `x0, x1, y0, y1`、五線数 `staves`、ピアノの組 `piano_pair`（段内の五線番号） |

### staves[]

`id`, `role`（`voice` / `piano_rh` / `piano_lh`）, `name`, `clef`, `voice_type`,
`octave_shift`（テノールのト音記号は -1）, `midi_program`, `measures[]`。
全パートで小節数は同じ（ある段にないパートは休符の小節で補われる）。

**追加パート**（`"added": true`、2026-11-08追加）：途中の段だけに印刷されるパート（ヒスイの「Ten. solo」、明日の「Soloist」）。
`role` は `voice` で、ほかの声部と同じく再生・書き出しできる。印刷されていない段の小節は休符（`inferred_rest: true`、
小節の `warnings` に `added part not printed on …`）なので、UIではその区間を「休み」として薄く表示する、
パート一覧で「途中から」と添える、などができる。現れる段は `meta.added_parts[].systems`。
名前は譜面の表記（「Ten. solo」→「Tenor Solo」）、なければ合唱の種類から（男声合唱のト音記号→テノール）、それもなければ「Solo」。
`added` のないパートは従来どおり（キー自体を出さない）。

### measures[]

`number`（1始まり）, `page`, `system`（ページ内の段番号、0始まり）, `time_sig`, `key_fifths`, `clef`,
`repeat_start`, `repeat_end`, `ending_numbers`, `warnings`, `events[]`, **`bounds`**（下記）。

### events[]

`onset`・`duration`（4分音符=1の分数文字列 `"3/2"`）, `pitches`（MIDI番号、**実音**、昇順）,
`voice`, `tie_start/stop`, `slur_starts/stops`, `grace`, `inferred_rest`（補った休符）, **`place`**（下記）。

## 位置情報

### 座標系

- 原譜PDFの各ページを **幅1920 px** に描画した画像のピクセル座標（左上原点、yは下向き）。
  高さは `meta.layout.pages[].height`。どのページかは小節の `page`。
- PDFを別の大きさで表示するときは `表示倍率 = 表示幅 / 1920` を掛ける。
- 五線の高さ（`lines`）は**上の線から順に5本**。

### 小節：`measures[].bounds`

```json
"bounds": {
  "x0": 197.0, "lines0": [1518.0, 1532.0, 1548.0, 1561.7, 1576.1], "confidence0": 1.0, "snapped0": true,
  "x1": 635.0, "lines1": [1514.0, 1528.0, 1543.0, 1558.0, 1572.0], "confidence1": 1.0, "snapped1": true
}
```

- `x0`/`x1`：小節の左端・右端（小節線のx）。段の最初の小節の左端は五線の左端。
- `lines0`/`lines1`：その位置での五線5本の高さ。**小節の中は両端を直線で結べばよい**
  （傾き3°・軽い弓なりでも誤差は中央値0.06〜0.1間隔。検証は比較資料を参照）。
  - x での i 本目の線： `lines0[i] + (lines1[i] - lines0[i]) * (x - x0) / (x1 - x0)`
  - 線の間隔： `(lines[4] - lines[0]) / 4`
- `snapped`：画像上で縦線（小節線）を確認できたか。`false` のときxは認識モデルの推定位置
  （数ピクセル〜数間隔ずれることがある）で、`confidence` は0。
- `confidence`：1.0＝はっきりした縦線が1本、0.8＝やや弱い、0.6＝近くに縦線が複数（隣を拾った可能性）。
- `x1` 側がない小節：終わりの小節線が認識されなかった（段の最後など）。
- `bounds` がない小節：位置の記録がない（補った休符の小節、位置記録より前の認識結果）。

### 音符：`events[].place`（音のある音符）

```json
"place": {"x": 664.0, "heads": [
  {"pitch": 69, "x": 664.0, "y": 1551.9, "confidence": 1.0, "snapped": true}
]}
```

- `heads`：和音の各音の符頭。`x`・`y` は符頭の中心。
- `y` は**認識した音高**と音部記号と五線（小節両端の直線補間）から計算した高さ。
  `x` はその高さで見つけた符頭に吸着した位置。
- `snapped: true`：その高さに符頭が見つかった（`confidence` 0.5〜1）。
- `snapped: false`：見つからなかった。**多くは音高の誤認識**（符頭が上下に1つずれている等）か、
  位置推定が大きくずれた場合。xは推定位置、yは認識音高から計算した高さのまま。
  エディターでは「要確認」の印に使える。
- `heads[].pitch` は**記譜上の音高**（認識結果そのまま）。`events[].pitches` は補正後の**実音**
  なので、テノールのト音記号（`octave_shift: -1`）では12違う。音域補正で変わることもある。
  対応付けは個数が同じなら「`heads` を pitch の昇順に並べた順 ＝ `pitches` の順」。
- 点（付点）・符尾・臨時記号の位置は出していない。

### 休符：`events[].place`（`pitches` が空）

```json
"place": {"x": 414.4, "confidence": 0.0, "snapped": false}
```

- 休符は吸着しない。`x` は認識モデルの推定位置（目安）。`y` はなし。

### 位置がないもの

- 補った休符（`inferred_rest`、ピアノだけの段の声部など）、全休符の連続（多小節休符）の展開分。
- 後処理で新しく作られた音（リズム修復で分割された音など）。
- 位置を記録する前（2026-11-08より前のアプリ）で認識したページ。再変換時に段組みと一緒に自動で
  付け直されるが、注意位置（attention x）を持たない古い認識結果では付かない（再認識が必要）。

## 実装の場所

| 処理 | ファイル |
|---|---|
| 小節線・符頭の吸着、小節両端の五線の高さ | `android/.../omr/SymbolPlacement.kt` |
| ページデータへの格納（`places`、段組みと同じ `LAYOUT_VERSION`） | `android/.../omr/PdfOmrEngine.kt` |
| 記号への付与（`SymbolPlace`、`withPlaces`） | `lib/omr_symbols.dart`, `lib/omr_bridge.dart` |
| 小節 `bounds`・音符 `place` の作成 | `lib/omr_staff_assembler.dart` |
| JSONの入出力（`Measure.bounds`, `NoteEvent.place`） | `lib/score_ir.dart` |
| 声部名の表記読み取り | `lib/voice_labels.dart` |

テスト：`test/symbol_place_test.dart`（Dart）、`SymbolPlacementTest`（Kotlin）。
