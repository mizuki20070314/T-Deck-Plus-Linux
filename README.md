# T-Deck Plus Linux

LilyGO **T-Deck Plus**（ESP32-S3 N16R8 / 16 MB flash / 8 MB PSRAM）で Linux を動かすための、
カーネル移植・デバイスドライバ・コンソールアプリ・開発ツールの詰め合わせです。

[paulneja/Linux-on-esp32-S3](https://github.com/paulneja/Linux-on-esp32-S3) 0.9.1 の
「Core 0 = ESP-IDF（Wi-Fi/BLE）、Core 1 = Linux（NOMMU / XIP）」構成をベースに、
T-Deck Plus 固有の画面・入力・音声・キーボードを追加しています。

> **このリポジトリはソースとスクリプトだけです。**
> ビルド済みのカーネル/ファームウェアイメージ、フラッシュの丸ごとバックアップ、
> パスワードや SSH 鍵（`secrets/`）は意図的に含めていません。
> バイナリは `build-scripts/` から再生成してください。

## このボードでできること

- **Linux 7.2.4 が直接 Xtensa で動く**（エミュレーションなし）。Core 0 が Wi-Fi/BLE を担当。
- **3.2 インチ ST7789 LCD（320×240）** にフレームバッファコンソール（fbcon）を表示。
- I2C キーボード（ESP32-C3）、トラックボール、GT911 タッチパネルを evdev 入力として使用。
- スピーカー（I2S0 / MAX98357A）とマイク（I2S1 / ES7210）の ALSA カード。
- Wi-Fi（STA のみ、WPA2-PSK/オープン）、SSH/Telnet、BLE 経由の Wi-Fi 設定。
- 画面上で `tdeckctl`（Wi-Fi、明るさ、音声状態、システム情報、フォント）を実行。
- `htop` / `fastfetch` を画面に表示、`screend` でブラウザから表示を切り替え。
- USB シリアル（ttyGS3）と LCD の tty1 の両方から root ログイン。

## リポジトリの構成

| パス | 内容 |
|---|---|
| `kernel-work/overlay/` | カーネルのソース変更（DTS、キーボード/音声/SPI/ディスプレイドライバ） |
| `kernel-work/config/` | `t-deck-plus.config` と Waveshare AMOLED 用の設定 |
| `kernel-work/patches/` | 上記ドライバを `git format-patch` したパッチ（出荷カーネル基準） |
| `kernel-work/debug-harness/` | 画面が真っ暗になった原因を追った診断コード（最終イメージには入っていない） |
| `patches/` | Core 0 ファームウェア用のパッチ（DMA 予約、IDF 互換） |
| `build-scripts/` | WSL 上で動かすビルド/検証スクリプト（`.sh`、CMake ツールチェーン） |
| `tools/` | 実機操作、画面キャプチャ、TUI、C の小物（`tdeckctl.sh`、`evpeek.c`、`ttyshell.py` など） |
| `HTOP.md` | htop の移植、NOMMU の連続メモリ問題、自動起動の記録 |
| `SCREEN.md` | `screend`（Web 画面管理）、fastfetch の移植の記録 |
| `KERNEL-REBUILD.md` | Waveshare AMOLED 向けカーネル再ビルドの詳細（背景資料） |
| `T-DECK-PLUS.md` | T-Deck Plus 用カーネルの概要とビルド手順 |
| **`T-DECK-PLUS-SPEC.md`** | **アプリ開発向けの HW/SW 仕様書（ピン配置、制約、ツールチェーン、実装ガイド）** |

## まず読むもの

- アプリを作る → **`T-DECK-PLUS-SPEC.md`**
  GPIO 割り当て、I2C アドレス、evdev の使い方、NOMMU の 256 KiB 制限、
  uClibc で使えない関数、クロスコンパイルのフラグ、画面への描画方法などをまとめています。
- カーネルをビルド/書き換える → `T-DECK-PLUS.md` と `KERNEL-REBUILD.md`
- 画面に htop/fastfetch を出す → `HTOP.md` と `SCREEN.md`

## ビルド環境

WSL（Ubuntu 24.04、**aarch64 ホスト**）でクロスビルドします。

- ツールチェーン: `~/esp32s3/build/crosstool-NG/builds/xtensa-esp32s3-linux-uclibcfdpic/bin/`
- 動的構成: `export XTENSA_GNU_CONFIG=~/esp32s3/build/xtensa-dynconfig/esp32s3.so`
- カーネル: `wsl -d Ubuntu -u builder -- bash /mnt/c/.../build-scripts/wsl-run-t-deck-plus.sh`
  → `kernel-work/out/xipImage-t-deck-plus`（4 MiB の `linux` パーティションに収まること）

PowerShell から `wsl -d ... bash -lc "...$VAR..."` とすると `$` が PowerShell 側で展開されて壊れます。
`wsl -d Ubuntu -u builder -- bash /mnt/c/.../script.sh` のように**スクリプトファイル経由**で実行してください。

## 実機への書き込み

**カーネルだけ**を `linux` パーティション（オフセット `0x140000`、4 MiB）に書きます。
フルイメージの書き込みは `/etc` と `/home` を初期化するので使いません。

```powershell
powershell -File tools\kernel_test.ps1 -Image kernel-work\out\xipImage-t-deck-plus
```

tools\restore_kernel.ps1 で出荷カーネルに戻せます。書き換え前に `backup/` のフルダンプを取ってください
（このリポジトリには含めていません）。

## 実機の操作

- USB シリアル: `tools/ttyshell.py COM24 <パスワードファイル>`（ログイン、base64 アップロードに対応）
- ヒアドキュメントは使えません（各行の末尾に `; echo "[[END:$?]]"` が付くため）。
  `printf '%s' '<base64 1000文字>' >> /run/x.b64` を連鎖させ、`base64 -d` で戻します。
- スクリプトは **LF 改行**で送ってください。CRLF だと `#!/bin/sh\r` になって実行できません。
- `ssh` は dbclient のラッパーです。`ssh sakura` / `ssh desktop` を使います。
  OpenSSH 形式の ed25519 鍵は読めないので、Dropbear 形式（`*_db`）を使ってください。

## 主な制約

- **NOMMU**: 実行コード（最初の R+E LOAD）は 262,144 バイト以下にすること。超えると
  512 KiB の連続 RAM が要り、動かし続けたボードでは起動できません。
- **RAM 7.8 MB**: `MemAvailable` は通常 2 MB 前後。プロセスを起こすたびに 64 KiB の連続領域が要ります。
  `sed`/`grep`/`awk` をループで起こすシェルより、常駐 1 プロセスが安全です。
- **fork** は swapped-bank バックエンド（CoW なし、プロセス間保護なし）。
  「fork して exec」なら `vfork()` を使ってください。
- **日本語は表示できません。** VT のフォントは最大 512 グリフで、CJK と全角幅を扱えません。
  ASCII と CP437（罫線 `─│┌┐└┘` など）だけを使ってください。
- Wi-Fi は STA のみ（AP になりません）。802.1X（Enterprise）は未対応です。
- 時刻はバッテリー保持の RTC が無く、起動時に保存値を戻して NTP で合わせます。

## ライセンス / 出典

このリポジトリのオリジナルのコードは、元のプロジェクトと同じく
**GPL-2.0-or-later** として扱ってください（各ファイルの SPDX ヘッダを参照）。

- ベース: [paulneja/Linux-on-esp32-S3](https://github.com/paulneja/Linux-on-esp32-S3)
- カーネル: [paulneja/linux-esp32s3](https://github.com/paulneja/linux-esp32s3)
- ピン配置と初期化シーケンス: LilyGO T-Deck Plus の資料、Zephyr `t_deck` board 定義
- Wi-Fi: [esp-hosted](https://github.com/espressif/esp-hosted) をベースにした ESP-IDF ファーム
