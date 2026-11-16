# アプリアイコン素材「音鳥」（A2）

「音取り」を言いかえた「音鳥」。八分音符の玉を鳥の体に見立て、旗を羽根、後ろに尾羽を付けたアイコン。

| ファイル | 用途 |
| --- | --- |
| `ototori_icon.svg` | マスター（108dp キャンバス。中央 72dp が表示領域） |
| `android/res/drawable/ic_launcher_foreground.xml` | アダプティブアイコン前景（VectorDrawable） |
| `android/res/drawable/ic_launcher_monochrome.xml` | Android 13+ テーマアイコン用の単色レイヤー（目はくり抜き） |
| `android/res/values/ic_launcher_background.xml` | 背景色 `#1E2A6E` |
| `android/res/mipmap-anydpi-v26/ic_launcher*.xml` | アダプティブアイコン定義 |
| `png/mipmap-*/ic_launcher*.png` | API 25 以下向けの PNG（角丸・丸） |
| `png/play_store_512.png` | Play ストア掲載用 |
| `png/icon_full_1024.png` | 大サイズ（資料・ストア素材用） |
| `png/adaptive_foreground_432.png` | 前景のみ（透過）・確認用 |
| `archive/c3_shield/` | 以前の案（盾と音符、C3） |

組み込むとき: `android/res/` 以下と `png/mipmap-*` を `android/app/src/main/res/` へコピーし、
`AndroidManifest.xml` の `<application>` に `android:roundIcon="@mipmap/ic_launcher_round"` を追加する。
アプリ名を変えるなら `android:label="音鳥"` も。

PNG の再生成: `python render_icons.py`（Pillow と Chrome/Edge が必要）。
SVG を変えたら VectorDrawable 側の座標も合わせて直すこと。

配色: 紺 `#1E2A6E` / 金 `#F2C12E` / くちばし `#E39A1C`
