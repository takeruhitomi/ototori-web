# Androidエミュレーターの復旧とデバッグ

2026-11-07。Windows 11 10.0.26300、Android 15 / API 35、x86_64、
AVD `choir_phone`。実機には操作・インストールを行っていない。

## 起動問題の切り分け

既存のAndroid Emulator 37.2.13では、WHPXの診断は正常でも、QEMUの
初期化後にADBが`offline`のまま止まった。コールドブート、
SwiftShader、Vulkan無効化、CPU仮想化無効化でも再現した。

Googleの[37系の修正記録](https://developer.android.com/studio/releases/fixed-bugs/emulator/37)
には、37.3.6でWindowsの起動停止（Issue #568816248）を修正した記録がある。
公式配布の37.3.8 Canaryをチェックサム検証して導入したところ、
**既存AVDのデータを消去せず**、WHPXを使った起動が成功した。
内部の停止原因を断定するものではないが、この環境では旧版と修正版の差で
問題を切り分けられた。37.3.8は今回検証した版として固定している。

以下を実測した。

- ADB `emulator-5554 device`
- `sys.boot_completed=1`、`init.svc.bootanim=stopped`
- ホーム画面のActivity起動
- `emulator.ps1`経由の再起動、および起動スクリプト終了後の接続維持
- 既存の保存済み楽譜の保持

旧版SDKは`work/mobile-sdk/emulator-backup-20261107-160430`に残している。
AVDは`work/mobile-sdk/android-user/avd/choir_phone.avd`を継続利用する。

## 起動・停止・デバッグ

リポジトリのルートで実行する。通常は設定済みなので、セットアップの再実行は不要。
セットアップスクリプトは導入済みの同じ版なら何も変更しない。

```powershell
# SDKを新たに用意した場合の修正版導入（AVD・Flutter SDKは既存のものを利用）
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/setup_mobile_emulator.ps1

# バックグラウンドで起動し、Androidの起動完了まで確認
powershell -NoProfile -ExecutionPolicy Bypass -File apps/choir_mobile/emulator.ps1

# ウィンドウを表示して起動したい場合（停止後に実行）
powershell -NoProfile -ExecutionPolicy Bypass -File apps/choir_mobile/emulator.ps1 -ShowWindow

powershell -NoProfile -ExecutionPolicy Bypass -File apps/choir_mobile/emulator.ps1 status
powershell -NoProfile -ExecutionPolicy Bypass -File apps/choir_mobile/mobile.ps1 run -d emulator-5554
powershell -NoProfile -ExecutionPolicy Bypass -File apps/choir_mobile/emulator.ps1 stop
```

起動はスナップショットを使わず、SwiftShader・Vulkan無効で行う。
タイムアウトやプロセス終了を成功として扱わない。
ログは`work/mobile-sdk/emulator-5554.stdout.log`と
`work/mobile-sdk/emulator-5554.stderr.log`に残す。
`-Silent`を付けた場合だけホスト音声出力を無効にする。

`mobile.ps1`も修正した。`ANDROID_SDK_HOME`と`ANDROID_USER_HOME`の
異なる設定先がAndroid Gradle Pluginに拒否されていたため、
非推奨の`ANDROID_SDK_HOME`を除去した。またWindows PowerShell 5.1で
Flutterの引数がひとつの文字列に結合される問題を修正した。
システム全体のPATHや実行ポリシーは変更していない。

## 今回のアプリ確認

0.1.6+7のモデル同梱x86_64デバッグAPKをビルドし、仮想端末へ上書きした。
既存の11ページ・69小節の保存済み楽譜を開いて以下を確認した。

| 操作 | 結果 |
|---|---|
| 認識の注意 | 88件の注意を件数表示つきで折りたたみ、詳細を展開可能に修正 |
| 全声部の通し再生 | 位置表示の進行と、アプリのAudioTrackがactiveであることを確認 |
| 一時停止 | 48.8拍の位置を保持し、再開ボタンへ切り替わる |
| シーク・再開 | 138.0拍へ移動後、再開して141.1拍まで進む |
| 原小節へ移動 | 141.1拍の位置から36小節目へ移動 |
| 半音変更・自動保存 | 36小節目のF5をF♯5に変更し、保存ファイルの音高78とUndo履歴を確認 |
| 再起動・Undo | アプリ再起動後にライブラリを開き、Undoで元のF5へ戻して保存されたことを確認 |

Flutterテスト91件成功、1件は実PDFの追加データが必要なためスキップ。
`flutter analyze`は指摘なし。デバッグAPKビルド成功。
音質や実際に耳で聞いた音は今回検証していない。

スクリーンショットと操作採取はGit対象外の`work/emulator-*.png`、
`work/emulator-*.xml`に置いた。今回の保存済み楽譜は以前の認識結果なので、
最新の自動編成判定や全PDFの新規認識が正しいことの証拠にはしない。

## ブラウザ版との機能差（起動復旧時点の記録）

以下は起動復旧時点の差分である。0.1.7で実装・検証を進めた。
最新の機能一覧と確認範囲は[BROWSER_PARITY.md](BROWSER_PARITY.md)を参照。

ブラウザ版の`choir_omr/webapp/static/index.html`、`app.js`、`player.js`と
Android実装の比較で、以下を後続作業として挙げた。

- 再生中のテンポ・音量・ミュート変更の即時反映。現在は試聴開始時の設定を使う。
- 複数声部のSolo、全体音量、音色選択、ミキサー初期化。
- メトロノーム、カウントイン。
- 原譜上の演奏位置表示・追従と、原譜をタップして移動する操作。
- 再生順に基づくループ範囲指定、現在位置からの範囲設定、
  手動の反復・括弧編集。

外観の仕上げと分け、実行時の操作と機能を基準に進める。
ブラウザ版との同等性やAndroid版全体の完成を確認したものではない。
