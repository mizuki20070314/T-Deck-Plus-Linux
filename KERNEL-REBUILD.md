# AMOLED 対応カーネルの再ビルド（記録）

T-Deck Plus 向けの別プロファイル（ST7789、GT911、I2Cキーボード、トラックボール）は
[`T-DECK-PLUS.md`](T-DECK-PLUS.md) を参照。既存のWaveshare用設定は変更していない。

2026-10-30。Waveshare ESP32-S3-Touch-AMOLED-1.43 の 1.43型AMOLED（466×466、QSPI、CO5300）にLinuxのfbconを出すため、
paulneja/Linux-on-esp32-S3 0.9.1 のカーネルを再ビルドした。実機には**カーネルだけ**（`linux` パーティション 0x140000）を書いてある。
2026-10-31 に、円形ガラスに収まるようコンソール領域を縮め（下の「円形ガラスに合わせたコンソール」）、htop を載せ、起動時に自動で出るようにした（`HTOP.md`）。

## 結果

| 項目 | 内容 |
|---|---|
| ビルド環境の検証 | 変更前のソースを WSL2 で再ビルドした `xipImage` が、出荷版（sha256 `79389da8c8ca10b74fabee1a72408ce3feadd9ca19dd686f26255120cc685fde`）と**バイト単位で一致** |
| 新カーネル | `kernel-work\out\xipImage-amoled`（2,560,352バイト、出荷版より約141KB増。4MBのパーティションに収まる）。sha256 `a764d6922d49ec237b825832eb4810d9971d5ea67d159a54702dba66bb3c8598`。円形に縮める前の全面（466×466）版は `xipImage-amoled-466full`（sha256 `a40bfd6360b899437741c8bc03b118a8e423e5207cac839b52e4e923f57bb3c3`） |
| 起動 | 起動する。`amoled-qspi-fb spi0.0: CO5300 328x320 (x offset 74), 4-wire pixels, fb0`、`Console: switching to colour frame buffer device 41x20`（全面版は 466x466、58x29） |
| パネルへの転送 | SPIの統計でエラー0、タイムアウト0。再起動後も毎回初期化される。コンソールに400行出す負荷試験でも dmesg に警告なし |
| 速度 | コンソール領域の全更新 約40ms（104,960画素、約5MB/s）。全面版は約125〜130ms（217,156画素）。カーソル点滅の更新 約0.5ms |
| メモリ | フレームバッファは 328×320×2 = 210KB（全面版は438KB）。起動直後の `MemAvailable` は約3.2MB |
| 画面の見え方 | 全面版を `tools\display_demo.ps1` の A（全面白）・B（テストパターン）・C（文字グリッド）で目視し、**すべて正常**（2026-10-30）。円形に縮めた版は htop を表示して写真で確認（2026-10-31） |

## Waveshare向け変更点（3パッチ + 設定）

1. **spi: esp32: support dual and quad writes, and frame messages with CS**（`drivers/spi/spi-esp32.c`）
   転送ごとの `tx_nbits` で `SPI_FWRITE_DUAL/QUAD` を立てる。多線の書き込みは半二重。QUAD機器はデータ線のアイドルをHighにする（ESP-IDFと同じ）。
   実装していなかった多線読み出しの宣言（`SPI_RX_DUAL/QUAD`）は外した。
   **CS の扱いも直した**（これが無いと画面は真っ暗。下の「最初のビルドで真っ暗だった件」）。`set_cs` で MISC を書いたあとに `SPI_UPDATE` を書き、CS を離すときは `SPI_CS_DIS` で CS ラインを止める。
2. **xtensa: dts: add the Waveshare ESP32-S3-Touch-AMOLED-1.43**（`esp32s3-waveshare-amoled-143.dts`）
   SPI2 のパネルのピンは IO_MUX のSPI2ピンと違うので、6本全てを GPIO マトリクス（`gpio_out_mux`）経由で割り当てる。

   | GPIO | パネル | SPI2の信号（番号） |
   |---|---|---|
   | 9 | CS | FSPICS0 (110) |
   | 10 | CLK | FSPICLK (101) |
   | 11 / 12 / 13 / 14 | D0 / D1 / D2 / D3 | FSPID (103) / FSPIQ (102) / FSPIWP (105) / FSPIHD (104) |
   | 21 | リセット（Low有効） | GPIO |
   | 42 | 電源EN | GPIO（リセット後はJTAGのMTMSなので IO_MUX 機能1を明示） |

   `console=tty0` と `fbcon=font:VGA8x16` をカーネル引数に追加。`mmc_spi` の子ノードは外した。
   パネルの `width`/`height`/`x-offset`/`y-offset` は円形ガラスに収まる 328×320（下の「円形ガラスに合わせたコンソール」）。
3. **video: fbdev: add a Quad-SPI AMOLED (SH8601/CO5300) driver**（`drivers/video/fbdev/amoled-qspi-fb.c` + Kconfig/Makefile）
   RAM上のRGB565フレームバッファ。描画した矩形を覚えて、20ms後に遅延workでパネルへ送る。
   レジスタ書き込みは `02 00 cmd 00` + パラメータ（1線）、画素は `32 00 2C/3C 00` + データ（4線、先頭は `2C`、続きは `3C`）。
   ベンダーのデモと SH8601 データシートに合わせている。書き込みウィンドウは偶数開始・奇数終了に広げ、CO5300 は X に +6。
   初期化のときに、フレームバッファより先にパネルの全面（466×466）を黒で塗る。リセットではパネルのフレームメモリが消えないので、フレームバッファが小さいと、覆われない部分が緑に光る（円形に縮めた直後の写真で見つかった）。
4. **設定**（`kernel-work\config\waveshare-amoled-143.config`）
   出荷設定から `INPUT`・`VT` の無効行を外し、`VT`/`FB`/`FRAMEBUFFER_CONSOLE`/`FONT_8x16` を追加。
   VT が連鎖で有効にする PS/2・マウス・HID・SERIO は明示的に切った（キーボード用の入力フレームワークは残してある）。

## 最初のビルドで真っ暗だった件（原因と切り分け）

最初に書き込んだカーネルは、起動もSPIの統計もエラー0なのに、全点灯コマンド（`echo 23 > cmd`、画素データ無し）でも何も光らなかった。

**原因は CS（GPIO9）が常時 Low のままだったこと。** CLK と D0 は正しく動いていたが、パネルは命令の区切りを受け取れなかった。

- `esp32_spi_set_cs()` は MISC を書くだけで `SPI_UPDATE` を書かず、変更が SPI モジュールに伝わらない（次の転送が始まるまで）。
- `CS_KEEP_ACTIVE` を落としただけでは CS は上がらない（CS はトランザクションの終わりにしか解放されない）。離すには `SPI_CS_DIS` で CS ラインを止める。
- 直したあとの CS は、待機 High → 書き込み中 Low → 終了後 High。トレースで確認した（`kernel-work\debug-harness\README.md`）。

切り分けの流れ: パッドとGPIOマトリクスのレジスタダンプ（設定は設計どおり）→ 各ピンを手で駆動して読み戻す → ドライバ経由の書き込みで CS/CLK/D0 を µs 付きでサンプル（CS だけ動かない）→ SPI エンジンを手でプログラムして1MHzで観察（手で組めば CS は正しく枠を作る）→ ドライバの流れとの違いを詰める。
途中で踏んだ罠: `GPIO_FUNCn_OUT_SEL_CFG` の bit9 は出力の反転で、「GPIO出力・OE強制」は `256 | BIT(10)`。`SPI_CLOCK_REG` の `CLKCNT_N` は6bit（最大63）。

## 円形ガラスに合わせたコンソール（2026-10-31）

パネルは円形（直径が466ピクセル）なので、466×466 の正方形の四隅は見えない。全面のコンソールだと、左上の `CPU[` のような行頭が欠けた。
円に内接する最大の 8×16 フォントのコンソールは **41×20 文字 = 328×320 ピクセル**（隅までの距離 229px < 半径 233px）。これを中央に置く。

| DTS（`display@0`） | 値 | 意味 |
|---|---|---|
| `width` / `height` | 328 / 320 | フレームバッファの大きさ（偶数） |
| `x-offset` | 74 | 最初の画素のパネル上の列。見える範囲の68列目 + CO5300が隠している6列 |
| `y-offset` | 72 | 最初の画素のパネル上の行 |

- fbcon は縦400ピクセル未満だと 8×8 フォントを選ぶ（41×40 になった）ので、カーネル引数 `fbcon=font:VGA8x16` で 8×16 に固定した。
- 全面（466×466）に戻すには、`width = height = 466`、`x-offset = 6`、`y-offset = 0` にして、カーネル引数の `fbcon=font:VGA8x16` は外してよい。旧カーネルは `kernel-work\out\xipImage-amoled-466full`。
- 縮めたフレームバッファの外側は、ドライバが起動時に黒で塗る。
- `tools\fb_snapshot.ps1 -Round` は、フレームバッファを円形ガラスに置いて、見えない部分を暗く塗ったPNGを作る。写真を撮る前に収まり具合を確かめられる。

## 作業場所

| 場所 | 内容 |
|---|---|
| `kernel-work\overlay\` | 変更したソース（Waveshare/T-Deck Plus DTS、SPI/display/inputドライバ）。編集はここで行う |
| `kernel-work\patches\` | Waveshare用3本とT-Deck Plus用1本を `git format-patch` したもの（出荷カーネル＝forkbank 基準）。`build-scripts\wsl-verify-patches.sh` で検証 |
| `kernel-work\debug-harness\` | 暗転の切り分けに使った診断コード（最終版には入っていない）と、その使い方 |
| `kernel-work\config\` | 設定のシード |
| `kernel-work\out\` | `xipImage-baseline`（変更前、出荷版と一致）、各Waveshare/T-Deck Plusカーネル、`xipImage-shipped-0.9.1`、各 `config-*` と `System.map-*` |
| `kernel-work\testimg\` | `fbtest-<幅>.rgb565`（テストパターン。`display_demo.ps1` が実機の大きさに合わせて作る）と `.png` |
| `htop\` | htop のビルド成果物（`out\htop`）、リンク用に実機から取ったライブラリ（`board-libs\`）、画面のスナップショット。手順は `HTOP.md` |
| `build-scripts\` | WSL内で動かすスクリプト（カーネル用 `wsl-*.sh`、htop用 `wsl-htop-*.sh`） |
| `tools\` | PC側の道具（書き込み、復旧、表示デモ、`htop_show.ps1`、`htop_autostart.ps1`、`screen_install.ps1`、`fb_snapshot.ps1`）。`tools\screend\` は画面サービスのソースとページ（`SCREEN.md`） |
| `fastfetch\`、`screend\` | fastfetch と screend のビルド成果物（`out\`）。手順は `SCREEN.md` |
| WSL: `~/esp32s3/` | ビルド環境（Ubuntu 24.04 aarch64、ユーザー `builder`）。`build/` にツールチェーン、`src/linux-fork` に改造ツリー |

## 再ビルドして書き込む

```powershell
# 1. kernel-work\overlay\ のファイルを編集
# 2. WSLでオーバーレイを同期してビルド（増分で約15秒）
wsl -d Ubuntu -u builder -- bash /mnt/c/Users/mizuk/esp32s3-linux/build-scripts/wsl-run-amoled.sh
# 3. 実機に書き込み、SSHが戻るのを待ち、dmesgを保存
powershell -File C:\Users\mizuk\esp32s3-linux\tools\kernel_test.ps1 -Image C:\Users\mizuk\esp32s3-linux\kernel-work\out\xipImage-amoled
# 4. 戻す（出荷カーネルを書き戻す。/etc、/home、rootfsは無傷、約20秒）
powershell -File C:\Users\mizuk\esp32s3-linux\tools\restore_kernel.ps1
```

パッチを書き出し直すには `build-scripts\wsl-export-patches.sh`（そのあと `wsl-verify-patches.sh` で確認）。T-Deck Plusの4本目を安全に追加・検証するには、メインのWSL作業ツリーに触れない `build-scripts\wsl-export-patches-scratch.sh` を使う。
変更前のカーネルを作り直すには、`git -C ~/esp32s3/src/linux-fork checkout 62114e2` のあと `wsl-run-baseline.sh`（終わったら `git checkout -`）。
ビルドスクリプトは `GIT_DIR=/nonexistent` にしてある。しないと、ツリーがgit管理のため `7.2.4-forkbank-g<コミット>` になり、出荷版と一致しなくなる。

## 表示の確認と調整（実機）

```powershell
powershell -File C:\Users\mizuk\esp32s3-linux\tools\display_demo.ps1   # A 全面白 → B テストパターン → C 文字グリッド（残る）
powershell -File C:\Users\mizuk\esp32s3-linux\tools\fb_snapshot.ps1 -Round   # いま画面にある内容をPNGにする（円形ガラス込み）
```

`display_demo.ps1` の B と C は、実機が報告するフレームバッファとコンソールの大きさに合わせて作る。

起動状態の確認と負荷試験（dmesg の警告、sysfs、コンソールに400行出して更新統計とメモリを見る）は `tools\display_check.sh` を `scp -O` で実機の `/tmp` に置いて `sh /tmp/display_check.sh`。

| 操作（実機のsshで） | 効果 |
|---|---|
| `echo 23 > /sys/bus/spi/devices/spi0.0/cmd` / `echo 13 > …/cmd` | 全画素点灯 / 通常表示（画素データ無しで、電源・リセット・コマンド経路だけを確かめる） |
| `echo 80 > …/brightness`（0〜255） | 明るさ |
| `echo 1 > …/refresh` / `echo 1 > …/reinit` | 全画面を送り直す / パネルを初期化し直す |
| `cat …/flush_stats` | 更新回数と、直近・最大の更新時間 |
| `echo 1 > /sys/module/amoled_qspi_fb/parameters/pixel_wires` | 画素を1線で送る（4線で映らないときの切り分け。`4` か `0` で戻す） |
| `echo 1 > /sys/class/graphics/fbcon/rotate_all`（0〜3） | コンソールの向きを回す |
| `printf '\033[9;0]' > /dev/tty1` | 画面の自動消灯を止める（分単位、0で無効。既定は10分で消灯） |
| `cat /tmp/fbtest-328.rgb565 > /dev/fb0` | 画像を直接書く（RGB565、リトルエンディアン。大きさはフレームバッファに合わせる） |

## 注意・制約

- `spi-esp32` の CS の扱いを直したので、このドライバを使う他のデバイス（SDカードの `mmc_spi` など）の挙動も変わる。CS は本来の動きになるはずだが、今回の実機では試していない。
- **書き込んだのはカーネルだけ。** 全面書き込み（`flash.sh` 既定）や `flash.sh --parts` は出荷カーネルに戻し、`/etc` も初期化する（USB側ログインの追記も消える）。そのあとは `kernel_test.ps1` で新カーネルを書き直す。
- 表示領域は円形ガラスに収まる 328×320 にしてある。画面いっぱいに描くアプリ（`/dev/fb0` に直接）が 466×466 を使いたいときは、DTS を全面に戻して再ビルドする（上の「円形ガラスに合わせたコンソール」）。
- `waveshare,amoled-1.43-sh8601` 版（パネルIDが 0x86 の個体）は、実機が無いため未検証。この個体は `0xff` = CO5300。
- tty1 には起動時に `screend` が htop・fastfetch などを出す（`SCREEN.md`。入れていなければ `htop-launch`、`HTOP.md`）。ログインプロンプトは出していない（キーボードが無いため）。出したいときは、先に `tools\screen_install.ps1 -Uninstall`（と `tools\htop_autostart.ps1 -Disable`）で tty1 の行を外してから `echo 'tty1::respawn:/sbin/getty -L tty1 0 linux' >> /etc/inittab; kill -HUP 1`（あると tty1 を取り合う）。
- RAMが厳しい。フレームバッファが210KB、`MemAvailable` が約3.2MB（htop を動かし、SSHを1本つないだ状態で約2.0MB）。SSHセッションやbashを複数開くと不足しやすい。
- 静止画のままだとAMOLEDは焼き付く。既定のコンソール消灯（10分）を活かすか、明るさを下げる。起動時に出す htop は消灯を止め、輝度も最大のままにしてある（`htop_launch.sh` の `BLANK_MIN`、`HTOP.md`）。
