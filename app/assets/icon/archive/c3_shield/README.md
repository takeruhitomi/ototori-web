# アプリアイコン素材（C3：細い金縁の盾）

合唱団エンブレムの盾（四分割）・紺・金を取り入れた、五線と八分音符のアイコン。

| ファイル | 用途 |
| --- | --- |
| `choir_omr_icon.svg` | マスター（108dp キャンバス。中央 72dp が表示領域） |
| `android/res/drawable/ic_launcher_foreground.xml` | アダプティブアイコン前景（VectorDrawable） |
| `android/res/drawable/ic_launcher_monochrome.xml` | Android 13+ テーマアイコン用の単色レイヤー |
| `android/res/values/ic_launcher_background.xml` | 背景色 `#1E2A6E` |
| `android/res/mipmap-anydpi-v26/ic_launcher*.xml` | アダプティブアイコン定義 |
| `png/mipmap-*/ic_launcher*.png` | API 25 以下向けの PNG（角丸・丸） |
| `png/play_store_512.png` | Play ストア掲載用 |
| `png/adaptive_foreground_432.png` | 前景のみ（透過）・確認用 |

組み込むとき: `android/res/` 以下と `png/mipmap-*` を `android/app/src/main/res/` へコピーし、
`AndroidManifest.xml` の `<application>` に `android:roundIcon="@mipmap/ic_launcher_round"` を追加する。

PNG の再生成: `python render_icons.py`（Pillow と Chrome/Edge が必要）。
SVG を変えたら VectorDrawable 側の座標も合わせて直すこと。

配色: 紺 `#1E2A6E` / 盾 `#16204F` / 金 `#F2C12E` / 五線 `#F7F5EE` / 銀 `#C8C8C8`（14%）
