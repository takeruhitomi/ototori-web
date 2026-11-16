# iOS版 移植計画 — Macビルド中心の開発ランブック

2026-11-07 作成。**この文書を書いたのはWindowsマシンであり、ここに書くiOSコードは1つもビルド・実行されていない。** iOS実装は macOS 上の Xcode ビルドループの中で完成させる前提。Android版の実装状況は [移植状況](MODEL_PORT_STATUS.md) を参照し、iOS側も同じ形式で検証記録を追記する。

## 0. 現在完了しているもの（Windows側で作成）

- `ios/` フォルダー一式（Flutter 3.47.9 / リビジョン `c197ca5199` のテンプレートで `flutter create --platforms=ios` 生成）
  - `Runner/AppDelegate.swift` は SceneDelegate ライフサイクル（`FlutterImplicitEngineDelegate`）。チャネル登録は `didInitializeImplicitFlutterEngine` で行う
  - バンドルIDは Android と揃えて `jp.choiromr.mobile`、`IPHONEOS_DEPLOYMENT_TARGET = 15.0`
- `ios/Podfile` — `onnxruntime-objc ~> 1.24.1` と `opencv2 ~> 4.13.0` をピン留め済み（Android の `build.gradle.kts` と同一バージョン。トークン一致検証は同一ランタイム同士でしか意味がない）
- `scripts/sync_ios_native_assets.sh` — Android アセット（vocabulary.json・ピアノPCM・任意でモデルZIP）を `ios/Runner/NativeAssets/` へコピーし、SHA-256で原本一致を確認する
- Dart 画面（`lib/`）はプラットフォーム非依存のため**変更不要**。方法論・仕様は Android 版と同一のメソッドチャネルを実装するだけで済む

## 1. Mac セットアップ

```sh
# 1. Xcode（App Store）+ コマンドラインツール
xcode-select --install
# CocoaPods（Rubyはシステム由来で可。Homebrew ruby でも可）
sudo gem install cocoapods   # または brew install cocoapods

# 2. Flutter — Android実機検証と同じリビジョンに固定（テンプレート整合のため）
git clone https://github.com/flutter/flutter.git ~/flutter-choir
( cd ~/flutter-choir && git checkout c197ca5199e9ee5661e865596c9c07294dfab51c )
export PATH="$HOME/flutter-choir/bin:$PATH"
flutter --version   # Framework c197ca5199 / Dart 3.13.7 と一致すること
flutter doctor -v   # Xcode・CocoaPods の欄が緑であることを確認

# 3. ブランチ取得
git fetch origin && git checkout ios-prototype

# 4. 初回ビルド前準備（apps/choir_mobile で）
flutter pub get
flutter build ios --config-only --debug   # Generated.xcconfig を生成
( cd ios && pod install )
open ios/Runner.xcworkspace
```

Xcode で Signing（Team 設定）→ シミュレータ起動で雛形が立ち上がることを確認。**この時点ではチャネル未実装なので「PDFを選ぶ」は PlatformException になるのが正常。**

## 2. 移植範囲とファイル対応表

Android の Kotlin を 1:1 で Swift へ落とす。Dart 側は変更しない。

| Android (Kotlin) | iOS (Swift/ObjC++) | 実装メモ |
|---|---|---|
| `MainActivity.kt` | `Runner/AppDelegate.swift` + `Runner/ChannelHandlers.swift` | 3チャネル配線。認識・保存は直列 `DispatchQueue(label:"choir.omr")`、音声は別直列キュー+世代カウンタ。`FlutterResult` は必ずメインスレッドで呼ぶ |
| `omr/ModelStore.kt` | `Runner/Omr/ModelStore.swift` + `ZipReader.swift` | ZIP は **STORED 専用生成**（`scripts/build_mobile_model_bundle.py` 参照）だが、手動選択に備え DEFLATE も zlib (`libz.tbd`) の raw inflate で読む。SHA-256 は CryptoKit。`installed()` は毎回ハッシュ検証。staging→READY→rename で原子的公開、旧版は `.corrupt-UUID` へ隔離 |
| `omr/PdfPageRasterizer.kt` | `Runner/Omr/PdfRasterizer.swift` | PDFKit `PDFDocument(data:)` → `page.draw(with:.media,to:ctx)`。`kCGImageAlphaNoneSkipFirst`/PremultipliedLast の RGBA バックポートに白で塗ってから描画 |
| `omr/PageOmr.kt` | `Runner/Omr/PageOmr.swift` | 流れは Kotlin と同一（隣接五線補完・警告文言も一字一句揃える） |
| `omr/PageSegmentation.kt` | `Runner/Omr/PageSegmentation.swift` + `Omr/OrtBridge.h/.mm` | ORT 呼び出しは C API を ObjC++ シムに封じ込め（§5） |
| `omr/StaffGeometry.kt` | `Runner/Omr/StaffGeometry.swift` | 純ロジック。定数表（§4）を厳守 |
| `omr/StaffCanvas.kt` | `Runner/Omr/StaffCanvas.swift` + `Omr/OpenCVWrapper.h/.mm` | CLAHE とリサイズは OpenCV 実装そのものを使うため C++ ラッパー経由（§5） |
| `omr/StaffDecoder.kt` | `Runner/Omr/StaffDecoder.swift` | KVキャッシュの ORT 間受け渡しに注意（§5.3） |
| `omr/SymbolVocabulary.kt` | `Runner/Omr/SymbolVocabulary.swift` | `JSONSerialization` + CryptoKit でハッシュ照合 |
| `omr/RecognitionCache.kt` | `Runner/Omr/RecognitionCache.swift` | Android は StandardMessageCodec バイナリ。**iOS は同一データの JSON を格納し、名前空間を `symbols-v1-396-308-ios-json` に分ける**（両プラットフォームのキャッシュ混在防止）。`Data.write(options:.atomic)` |
| `ProjectStore.kt` | `Runner/ProjectStore.swift` | `Data.write(.atomic)`、検証ルール（≤10MB・`staves` 非空・UUID形式・version 1）を Kotlin と同一に |
| `MainActivity` の AudioTrack 合成 | `Runner/AudioEngine.swift` | `AVAudioEngine` + `AVAudioSourceNode`（mono Float32 44100）。数式は§4。`AVAudioSession` category `.playback` |
| Storage Access Framework | `Runner/DocumentPicker.swift` | `UIDocumentPickerViewController`。`startAccessingSecurityScopedResource()` 後すぐ一時領域へコピーして閉じる |
| `StaffBenchmarkActivity.kt`（debug ハーネス） | 第2段階：`Runner/DebugHarness.swift` | `ProcessInfo.processInfo.environment` の `CHOIR_DEBUG_MODE` で起動。mode: `staff` / `pdf-page` / `cache-export` / `cache-test` / `project-test`。結果は Application Support 直下に JSON（§8 参照） |

新規 Swift/ObjC++ は `ios/Runner/` 以下に置き、Xcode の *Runner* ターゲット Sources へ追加する（このプロジェクトの pbxproj はクラシック形式なので **Add Files 時に Target Membership にチェック**。「Add to Targets」が出ない場合はターゲット→Build Phases→Compile Sources で確認）。`NativeAssets` は**フォルダー参照（青いフォルダー）**として追加し、`models.zip` を同梱した場合も再追加不要にする。

## 3. メソッドチャネル仕様（Android と完全一致必須）

Dart 側 (`lib/omr_bridge.dart`, `lib/main.dart`, `lib/score_page.dart`) が期待する形式。値の型は Flutter の standard codec に載るもののみ。

### `jp.choiromr.mobile/omr`
| メソッド | 引数 | 成功時 | エラーcode |
|---|---|---|---|
| `modelsReady` | – | `Bool`（同梱 `NativeAssets/models.zip` があれば先に自動展開） | `models` |
| `importModels` | – | `Bool`（キャンセルは `false`） | `busy`, `picker`, `models` |
| `cancel` | – | `null` | – |
| `recognizePage` | `page:Int`, `dpi:300\|400` | `{"staves":[{"lines":[Double],"left":Int,"right":Int,"crop":[l,t,r,b],"reachedEos":Bool,"symbols":[[String×6]]}],"warnings":[String],"width":1920,"height":Int}` | `input`,`busy`,`cancelled`,`recognition`,`memory` |

### `jp.choiromr.mobile/score`
| メソッド | 引数 | 成功時 |
|---|---|---|
| `listProjects` | – | `[{"id":String,"title":String,"updated":Int(ms)}]` 新しい順 |
| `loadProject` | `id` | スコアJSON文字列 |
| `saveProject` | `id:String?`, `text` | 保存id |
| `pick` | – | JSONテキスト or `null`（キャンセル）。≤10MB |
| `save` | `text` | `Bool`（ファイル名 `score-edited.json`） |
| `saveMidi` | `bytes:UInt8List` | `Bool`（ファイル名 `choir-score.mid`。Android の `audio/x-midi` 相当は `UTType` の拡張子指定で再現し、`.mid` を必ず維持） |
| `stop` | – | `null`（世代++ で再生中断） |
| `play` | `events:[{pitch,start,duration,piano?,gain?,legato?}]`, `piano:Bool` | 音源ロード完了後 `null`（再生自体は非同期） |

`play` の検証範囲も Android と同一: events ≤ 50000、pitch 0..127、start ≥ 0、duration > 0、start+duration ≤ 1,800,000、gain は 0..1 の有限値。エラーcode: `busy`,`save`,`audio`,`project`,`picker`,`open`。

### `jp.choiromr.mobile/pdf`
| メソッド | 引数 | 成功時 |
|---|---|---|
| `pickPdf` | – | `{"name":String,"pages":Int}` or `null`。選択PDFはコピーして保持し、全文SHA-256を`pdfHash`として保持（キャッシュキー） |
| `renderPage` | `page`, `dpi` | `{"width","height","elapsedMs","pssBytes","bitmapBytes","preview":UInt8List(PNG)}` |

- `preview` は表示用縮小（長辺≤1200、`pssBytes` は Android の PSS 相当。iOS は `task_vm_info.phys_footprint` を使い、**PSSそのものではない**ことをUI注記で明記）
- `bitmapBytes` = 描画用RGBA画像のバイト数（幅×高さ×4）
- ピクセル上限 40,000,000 を超えたら「ページが大きすぎます。」で失敗（文言一致させる）

## 4. 数値パラティ定数（トークン一致のための厳守事項）

Kotlin 側から**転写のみ**、丸め・順序を変えるな。

- ページ前処理: 幅 1920 固定、`targetHeight = round(height × 1920 / width)`、`1920×targetHeight ≤ 16,000,000`
- グレースケール化: `(77·r + 150·g + 29·b + 128) >> 8`
- ページリサイズ: Android は `Bitmap.createScaledBitmap(filter=true)`。**iOS で OpenCV の INTER_LINEAR に置き換えると1ピクセル単位の差が出る可能性がある**（§9 検証①で必ず確認）
- CLAHE: `clipLimit=1.0, grid=8×8`（OpenCV 実関数を呼ぶ。セグメンテーション前に全ページへ適用）
- セグメンテーション: 320×320 パッチ、`step=320`、端は `min(row, size-320)` で往復重複。入力 `[1,3,320,320]` float、はみ出しは 255f。6クラスの argmax を重み無し整数平均（sum は Int16、count は UInt8）
- 五線幾何: ストリップ16、閾値 `max(3, round(stripW×0.12))`、間隔モード 4..60・最小支持4、クラスタ距離 `3×spacing`（同ストリップ不在時）/ `1.5×spacing`、支持数 `≥ max(2, 0.4×maxSupport)`、左右精査は連続 ink 判定（2本以上の行）。**すべて Kotlin のまま**（`StaffGeometry.kt` を横に置いて逐行対訳）
- 五線キャンバス: 切り出しマージン 左右 `2×spacing`・上下 `4×spacing`（隣接五線でクリップ）、1280×256 へ アスペクト保持リサイズ（縦優先判定 `cropH/cropW > 256/1280`）、白背景縦中央
- デコーダ入力: `(v/255 − 0.7931) / 0.1738` float32、shape `[1,1,256,1280]`。encoder 出力の**先頭512 float**を `[1,1,512]` にして step≥1 の `context` に使う（step 0 は encoder 出力そのもの）
- デコーダ入出力名: `rhythms,pitchs,lifts,articulations,slurs`（Int64 `[1,1]`）、`context`、`cache_len`（Int64 `[1]`）、`cache_in0..31`（float `[1,8,n,64]`、初回 `[1,8,0,64]` の空テンソル）、出力 `out_rhythms,out_pitchs,out_lifts,out_positions,out_articulations,out_slurs` と `cache_out0..31`。`rhythm==2` で EOS、`maxSteps=608`
- ボキャブラリ: SHA-256 `f47b3d8f7f356ad0a4d8a84acf78383118bba9d00196d15b2a49767955343013`、サイズ rhythm 259 / pitch 72 / lift 7 / position 3 / articulation 54 / slur 5
- モデル仕様: version 文字列 `homr-0_7-396-308`。segnet 57,311,361B `6ed36640…3a8d` / encoder 52,861,122B `4c16df85…d5eb` / decoder 47,299,551B `3e10fd5a…e57d`（完全値は `ModelStore.kt` をコピー）
- 音声: 44100Hz mono Int16。ノート開始 `start×rate/1000`（整数除算）、`envelope = min(1, age/220, (last−sample)/release)×gain`、release は `legato ? 441 : 2205`。ピアノはサンプル線形補間 `step = 0.5 × 2^((pitch−samplePitch)/12)`、歌声サイン波 `440×2^((pitch−69)/12)`。出力は `(clamp(value,−2,2)×7000)` を Int16 へ（**クランプ7000は飽和余裕のための意図的値**）
- ピアノサンプル: 16音（A0=21 … C8=108、`MainActivity.loadPianoSamples` の表）、22,050Hz mono 16bit PCM リトルエンディアン

## 5. ネイティブ相互運用の設計

### 5.1 ORT は C API を ObjC++ シムに閉じ込める
`onnxruntime-objc` の Objective-C クラスはバージョン间でセレクタが変わった実績がある。C API（`OrtGetApiBase()->GetApi(ORT_API_VERSION)`）は ABI 安定のため、`ios/Runner/Omr/OrtBridge.h/.mm` にのみ ORT 依存を集約し、Swift には以下だけを公開する。

```objc
@interface OrtBridgeEnv : NSObject            // CreateEnv + Options(2,1)
- (nullable OrtBridgeSession *)sessionForPath:(NSString *)path error:(NSError **)error;
@end
@interface OrtBridgeSession : NSObject
- (nullable NSDictionary<NSString *, OrtBridgeTensor *> *)
    runWithInputs:(NSDictionary<NSString *, OrtBridgeTensor *> *)inputs
      outputNames:(NSArray<NSString *> *)outputNames error:(NSError **)error;
@end
@interface OrtBridgeTensor : NSObject          // float / int64 を形状付きで保持
+ (instancetype)floats:(NSData *)data shape:(NSArray<NSNumber *> *)shape;
+ (instancetype)int64s:(NSArray<NSNumber *> *)values shape:(NSArray<NSNumber *> *)shape;
+ (instancetype)emptyFloatsShape:(NSArray<NSNumber *> *)shape;  // [1,8,0,64] 用
@end
```

C ヘッダーのインクルードは `#if __has_include(<onnxruntime/onnxruntime_c_api.h>)` を第一候補に、pod の実際のヘッダーパスへは `HEADER_SEARCH_PATHS` で対応する（初回ビルド時の想定修正ポイント）。

### 5.2 OpenCV は必要関数のみを C++ ラッパーへ
`OpenCVWrapper.h/.mm` で `cv::createCLAHE(1.0, cv::Size(8,8))` と `cv::resize(INTER_LINEAR)`、グレースケール Mat の入出力だけ公開する。Swift から OpenCV の自動生成バインディングに依存しない（バージョン差に強い）。Runner ターゲットに `CLANG_CXX_LANGUAGE_STANDARD = gnu++17` が必要（OpenCV ヘッダー要件）。

### 5.3 デコーダの KV キャッシュ
Kotlin と同じく、前ステップの出力 `OrtValue` をそのまま次ステップの入力ポインタとして渡す（コピー禁止・所有権はステップ切替時のみ解放）。空キャッシュは `CreateTensorWithDataAsOrtValue` を `dataLength=0`・shape `[1,8,0,64]` で作る（`nullptr` データは環境差があるので 4 バイトの実バッファを渡す）。

## 6. アセットとモデル同梱

```sh
cd apps/choir_mobile
sh scripts/sync_ios_native_assets.sh
# 個人検証用にZIPを同梱する場合:
CHOIR_MODEL_BUNDLE=$HOME/models/homr-0.7.zip sh scripts/sync_ios_native_assets.sh
```

`ios/Runner/NativeAssets/` を Xcode の**フォルダー参照**で追加すると `Bundle.main` 直下に `omr/vocabulary.json`、`piano/*.pcm`、`models.zip` として現れる。`ModelStore.swift` は `Bundle.main.url(forResource:"models",withExtension:"zip",subdirectory:"NativeAssets")`（配置により `subdirectory` を調整）を見る。`NativeAssets/models.zip` は Git 対象外（`ios/.gitignore` に追加済み）。`.gitignore` に `NativeAssets/piano/*.pcm` 等は**入れない**こと（原本は android 側にあり、同期スクリプトがSHA-256で保証する）。

## 7. ドキュメントピッカー実装方針

- 開く: `UIDocumentPickerViewController(forOpeningContentTypes:)` + `UTType.pdf` / `.json` / `.zip`（`UTType(filenameExtension:)` のフォールバックも可）
- 保存: 一時ファイルへ書き出してから `UIDocumentPickerViewController(forExporting: [url], asCopy: false)`。ファイル名は一時ファイル名で決まる（`score-edited.json` / `choir-score.mid`）
- セキュリティスコープ: ピッカーコールバック内で `startAccessingSecurityScopedResource()` → 即コピー → `stopAccessingSecurityScopedResource()`。PDF はアプリの Application Support へコピーして保持し、アプリ起動中は再利用する（Android の「セッション中のみ開く」と同思想）
- `pickPdf` はコピー後に全文 SHA-256 を計算して返す。回転・再起動時の挙動は Android と同じ制約（未保存編集は失われる）でよい

## 8. 検証手順（この順で。各段を通過するまで次へ進まない）

1. **Dart回帰**: `flutter analyze`、`flutter test`（すべて pass。`real_pdf_assembly_test` は環境変数なしなら skip）
2. **雛形起動**: シミュレータでアプリ起動、「PDFを選ぶ」がエラーメッセージを出す（チャネル未登録の確認）
3. **チャネルスモーク**: `pickPdf`→`renderPage(300)`→プレビュー表示まで
4. **モデル導入**: 同梱ZIPから自動展開 → `modelsReady` が true。手動 `importModels` も確認
5. **五線トークン一致**: PC homr 0.7 CPU と同一画像で比較。Android 版の照合手順（`scripts/test_mobile_parity.ps1` と `scripts/compare_mobile_page_tokens.py`）を iOS ハーネス（§2 DebugHarness の `staff` mode）で再現。全トークンIDが一致するまで §4 の定数・前処理を疑う
6. **ページセグメンテーション一致**: サンプル画像で PC 参照と全画素一致（`scripts/mobile_segmentation_reference.py` 系を流用）。ここで §9 のリサイズ差が顕在化する
7. **実PDF 1ページ認識 → 楽譜画面 → 全声部再生**（Galaxy Tab S9 FE で済んだライン）
8. **キャッシュ往復**: `cache-export` 相当で `recognized-pages.json` を取り出し、Mac で `MOBILE_RECOGNIZED_PAGES=<path> flutter test test/real_pdf_assembly_test.dart`（複数ページ・全声部・再生イベント生成）。force-stop 相当（アプリ終了→再起動）で再選択後も保存済みキャッシュが再利用され、保存済みファイルの mtime が変わらないこと
9. **MIDI**: 書き出した `.mid` を `python scripts/verify_mobile_midi.py <dir>` で検証済み基準と SHA-256 一致
10. **ライブラリ**: 保存・一覧・読み戻し・音程編集・Undo/Redo・自動保存（`project-test` ハーネスで自己検証）
11. **実測記録**: 300/400dpi の描画時間・認識時間・ピークメモリ・発熱を表に。`MODEL_PORT_STATUS.md` に追記する形で iOS 版の検証記録を残す（実機 = 対象 iPhone/iPad を明記）

## 9. 既知のリスク（初回ビルドで壊れそうな箇所）

| 箇所 | 予兆 | 対処 |
|---|---|---|
| ORT ヘッダー/リンカ | `onnxruntime_c_api.h not found` / 未定義シンボル | pod のヘッダーパスへ `HEADER_SEARCH_PATHS`。`onnxruntime-c` と `onnxruntime-objc` のどちらを入れるか確認（ObjC クラスは使わない設計） |
| OpenCV pod | ビルド30〜90分 / `opencv.hpp not found` / C++ 標準エラー | `gnu++17`。pod 名は `opencv2`。使えなければ `OpenCV-Repackaged` 等へ代替し、Podfile のコメントに根拠を残す |
| ページリサイズ差 | §8-⑥ で画素一致しない | OpenCV 側で再現するか、Android の Bitmap スケーラ（libjpeg-turbo系）を参考実装。**トークン一致より下位なので先にセグ分一致を優先** |
| AVAudioSourceNode | 無音・ガサつき | 出力フォーマットは mono Float32 44100 で統一し、ミキサ接続時に明示指定。`AVAudioSession` は `.playback` を activate |
| pbxproj 手編集 | 追加ファイルがビルド対象外 | Compile Sources / フォルダー参照の青フォルダーを確認 |
| シミュレータの音声 | 聞こえない | 検証は実機で行う（Android と同じ流儀） |

## 10. 完了条件（Android 版の「未完成です」を踏襲した状態から始める）

- [ ] §8 の 1〜5 が通る（**トークン一致が最も重要な門**）
- [ ] 6〜10 が通る（正答率保証ではなく パイプライン完走の保証）
- [ ] README の iOS 節に「実機で確認できたこと／していないこと」を Android 版と同じ文体で記載
- [ ] `MODEL_PORT_STATUS.md` に iOS の検証記録（端末・OS・バージョン・時刻）を追記
- [ ] モデル重み・ZIP・Podfile.lock 以外のビルド成果物をコミットしない
