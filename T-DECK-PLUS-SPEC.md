# T-Deck Plus（ESP32-S3 Linux）ハードウェア／ソフトウェア仕様書

この端末向けにアプリケーションを作るときの参照資料。ハードウェアの配線、カーネルとユーザーランドの構成、
アプリから各デバイスを使う方法、NOMMU 特有の制約をまとめる。

- 対象: LilyGO T-Deck Plus（シリアル COM24、Wi-Fi MAC `28:84:85:1e:35:68`）。paulneja/Linux-on-esp32-S3 0.9.1 に、このリポジトリの T-Deck Plus 用カーネルとツールを加えたもの。
- 作成: 2026-11-19。実機を接続していない状態で、それまでのシリアルログ（`build-output\`）、DTS、カーネル設定、ドライバのソースからまとめた。
- 出典の印:
  - **[実機]** シリアルログで実機の値を確認したもの
  - **[DTS] / [設定] / [ソース]** DTS、カーネル設定、ソースコードから読んだもの（実機と同じビルド）
  - **[未確認]** 資料や推定によるもので、実機では確かめていないもの。使う前に確認すること

関連資料: `T-DECK-PLUS.md`（移植の経緯）、`HTOP.md`（NOMMU のメモリ問題）、`KERNEL-REBUILD.md`（カーネル作業）、
`dl-paulneja-docs\ARCHITECTURE.md`（上流の構成）。

---

## 1. 概要

| 項目 | 内容 |
|---|---|
| SoC | ESP32-S3FN16R8（Xtensa LX7 ×2）。**Core 0 = ESP-IDF（Wi-Fi/BLE ファーム）、Core 1 = Linux** |
| RAM（Linux） | PSRAM 8 MiB のうち `MemTotal` 7800 kB [実機]。起動後の `MemAvailable` は約 2.0〜2.6 MB [実機] |
| フラッシュ | 16 MiB。カーネルと rootfs は**フラッシュ上で直接実行（XIP）** |
| OS | Linux 7.2.4（forkbank 版）、**NOMMU**、単一 CPU、FDPIC 実行形式、uClibc-ng 1.0.48、Buildroot 2024.08 |
| 画面 | 2.8 インチ相当 ST7789、**320×240 RGB565**、`/dev/fb0` と fbcon（tty1） |
| 入力 | I2C キーボード（ESP32-C3）、トラックボール（GPIO）、GT911 タッチパネル |
| 音声 | スピーカー（I2S0 → MAX98357A）、マイク（I2S1 ← ES7210） |
| 通信 | Wi-Fi STA のみ（2.4 GHz、WPA2-PSK／オープン）、BLE（Wi-Fi 設定専用）、USB シリアル |
| 文字表示 | ASCII と CP437 の範囲（罫線を含む）。**日本語は表示できない**（§3.7） |

---

## 2. ハードウェア

### 2.1 SoC とコアの分担

```
ESP32-S3
├── Core 0: ESP-IDF / FreeRTOS（"network_adapter" ファーム、factory パーティション）
│     Wi-Fi 無線（クローズドな blob）、NimBLE、フラッシュ書き込みを担当
│     Core 1 とは共有メモリ IPC（ipc@600c0004、esp32-wifi-shmem）でやり取りする
└── Core 1: Linux 7.2.4 NOMMU
      esp32-ng ドライバ → espsta0（Wi-Fi STA）、/dev/esp-ble（BLE パイプ）
```

Linux から Wi-Fi のハードウェアは直接見えない。Wi-Fi の機能（モニターモード、AP、帯域など）はファームの対応範囲に縛られる。

### 2.2 Linux から見たメモリマップ [DTS/設定]

| アドレス | 内容 |
|---|---|
| `0x3d800000`〜`0x3e000000`（8 MiB） | Linux の RAM（PSRAM）。`CONFIG_DEFAULT_MEM_START` / `XIP_DATA_ADDR` |
| `0x42140000` | カーネル（XIP、`linux` パーティションの位置） |
| `0x42540000` | rootfs（cramfs、XIP） |
| `0x40380000` | Linux の例外ベクタ（Core 0 ファームの `space_for_vectors` と一致が必須） |
| `0x40381000`（IRAM）= `0x3fc91000`（DRAM エイリアス） | 音声 GDMA ディスクリプタ用のページ（ファーム側で予約、マジック `0x54444543`） |

### 2.3 フラッシュのパーティション [ソース]

| 名前 | オフセット | サイズ | 内容 |
|---|---|---|---|
| `nvs` | `0xa000` | 20 KiB | ESP-IDF NVS |
| `phy_init` | `0xf000` | 4 KiB | Wi-Fi PHY 校正 |
| `factory` | `0x10000` | 768 KiB | Core 0 ファーム `network_adapter.bin` |
| `etc` | `0xd0000` | 448 KiB | jffs2 → `/etc` |
| `linux` | `0x140000` | 4 MiB | `xipImage`（T-Deck Plus 版は約 2.7 MB） |
| `rootfs` | `0x540000` | 7.5 MiB | cramfs → `/`（読み取り専用、空き 0） |
| `home` | `0xcc0000` | 3.25 MiB | jffs2 → `/home` |

### 2.4 GPIO の割り当て [DTS]

| GPIO | 用途 | 備考 |
|---|---|---|
| 0 | トラックボール押下（`KEY_ENTER`） | BOOT ストラップと共用。Low 有効 |
| 1 | トラックボール左（`KEY_LEFT`） | Low 有効、デバウンス 2 ms |
| 2 | トラックボール右（`KEY_RIGHT`） | 同上 |
| 3 | トラックボール上（`KEY_UP`） | 同上 |
| 15 | トラックボール下（`KEY_DOWN`） | 同上 |
| 5 / 6 / 7 | I2S0 WS / SD / BCK（スピーカー） | GPIO マトリクス経由 |
| 8 | I2C SCL | i2c-gpio（ビットバング）、オープンドレイン |
| 18 | I2C SDA | 同上 |
| 9 | LoRa CS | High 固定（gpio-hog、非選択）。LoRa は未対応 |
| 10 | 周辺電源 | High 固定（gpio-hog）。**バッテリー駆動時に必須** |
| 11 | LCD D/C | |
| 12 | LCD CS | SPI2 FSPICS0 |
| 40 / 41 | SPI2 SCK / MOSI | LCD 専用、40 mA 駆動 |
| 14 | ES7210 SDOUT1（マイク入力） | I2S1 SD 入力 |
| 21 / 47 / 48 | I2S1 WS / BCK / MCLK（マイク） | |
| 16 | GT911 割り込み | 立ち下がりエッジ |
| 39 | SD カード CS | High 固定（gpio-hog、非選択）。SD は未対応 |
| 42 | LCD バックライト | High 固定（gpio-hog）。明るさは変えられない |
| 43 / 44 | UART0 TX / RX（GPS） | 9600 bps |
| 46 | キーボード IRQ | 入力設定だけで未使用（ポーリング方式） |

gpio-hog の線（9、10、39、42）はカーネルが持っているので、ユーザー空間からは操作できない。

### 2.5 バス構成

| バス | つながっているもの |
|---|---|
| I2C0（i2c-gpio、SDA18/SCL8） | `0x40` ES7210（マイク ADC）、`0x55` キーボード MCU、`0x5d` GT911 タッチパネル。`/dev/i2c-0`（`CONFIG_I2C_CHARDEV=y`） |
| SPI2（`spi0.0`） | ST7789 LCD（書き込み専用、最大 40 MHz、8 bit） |
| I2S0 | MAX98357A（再生）、GDMA チャネル 0、IRQ13 |
| I2S1 | ES7210（4 スロット TDM 録音）、GDMA チャネル 1、IRQ17 |
| UART0 | GPS（`/dev/ttyS0`） |
| USB Serial/JTAG | Linux コンソール `ttyGS3`（PC 側は COM24、115200） |

I2C はビットバングなので遅く、CPU を使う。キーボードが 10 ms ごとにポーリングしているので、`/dev/i2c-0` からほかの機器を頻繁に叩くと入力が遅れることがある [未確認]。

### 2.6 デバイスの詳細

#### LCD（ST7789V）[DTS][実機]

- パネルの元の向きは 240×320 の縦長。fbtft の `rotate = 270` で **320×240 の横長**にしている。
- `/dev/fb0`: `fb_st7789v`、16 bpp（RGB565、リトルエンディアン）、`virtual_size` は `320,240`、1 フレーム 153,600 バイト（1 行 640 バイト）。
- fbtft は RAM 上のフレームバッファを持ち、変更された部分を後から SPI で送る（deferred I/O）。
- バックライト（GPIO42）は常に点灯。明るさの調整と消灯の制御は実装していない。`/sys/class/graphics/fb0/blank` は書けるが、バックライトは消えない [未確認]。

#### タッチパネル（GT911）[DTS]

- I2C `0x5d`、割り込みは GPIO16。電源は GPIO10 の周辺電源系統。
- DTS の設定: `touchscreen-size-x = 240`、`size-y = 320`、`swapped-x-y`、`inverted-x`。**座標の変換が画面と一致しているかは、実機ではまだ確かめていない** [未確認]。アプリでは補正（キャリブレーション）できるようにしておくこと。
- Linux の `goodix` ドライバの evdev（マルチタッチ `ABS_MT_*`）として出る。

#### キーボード（ESP32-C3 MCU、I2C `0x55`）[ソース][実機]

キーボードはマトリクスを S3 に直接つないだものではなく、別の MCU（ESP32-C3、LilyGO のファーム）が I2C スレーブとして応答する。
カーネルドライバ `tdeck-keyboard.c` が 10 ms ごとにポーリングして、普通の evdev キーイベントに変換する。

| I2C 操作 | 意味 |
|---|---|
| 1 バイト読む | 押された文字の ASCII（無ければ `0x00`） |
| `0x01 <v>` を書く | キーボードバックライトの明るさ（0〜255） |
| `0x02 <v>` を書く | Alt+B で使われる既定の明るさ（31〜255） |
| `0x03` を書いてから 5 バイト読む | 生のキーマトリクス（5 列、各 1 バイト、7 行分のビット）。2025-06-12 以降のファーム |
| `0x04` を書く | 文字モードに戻す |

- 出るキー: `A`〜`Z`、`0`〜`9`、`SPACE`、`ENTER`、`BACKSPACE`、`TAB`、`ESC`、`` ` - = [ ] \ ; ' , . / ``、`LEFTSHIFT`、`LEFTCTRL`。記号はファームが送る ASCII を Shift 付きのキーに直したもの（US 配列の前提）。
- **Mic キー**（列 0、行 6）は、押している間 `LEFTCTRL` になる。SYM を押しているあいだは Ctrl にしない（SYM+Mic で `0` を打てるようにするため）。
- **SYM キー**（列 0、行 2）を単独で押して離すと、1 ポーリング（10 ms）後に `TAB` になる。ほかのキーと一緒に押したときは、従来どおり記号の修飾キーとして働く。
- 矢印キー、ファンクションキー、Alt、Meta は無い。矢印はトラックボールで代用する。
- 入力ノードは `/dev/input/event0` だった [実機]。番号は登録順で決まるので、アプリは `/sys/class/input/input*/name` が `LilyGO T-Deck I2C Keyboard` のものを探すこと。
- sysfs: `/sys/bus/i2c/devices/0-0055/keyboard_backlight`（0〜255）、`.../keyboard_backlight_default`（31〜255）。MCU は再起動すると設定を忘れるので、`S99tdeck-console` が `/home/tdeck/keyboard-backlight*` から戻している。

#### トラックボール [DTS][実機]

`gpio-keys`（入力名は DTS の `trackball` ノード）。上下左右が `KEY_UP/DOWN/LEFT/RIGHT`、押下が `KEY_ENTER`。回した量ではなく、パルス 1 つが 1 回のキー押下になる。
割り込みは `esp32xx-gpio` の 0/1/2/3/15。

#### スピーカー（MAX98357A、I2S0）[実機]

- ALSA カード 0 `T-Deck Plus Speaker`、`/dev/snd/pcmC0D0p`、MCLK = 256fs。
- アンプの電源は GPIO10 の系統から取るので、SD モードの制御は無い。
- rootfs に `aplay` が無いので、**音を出す試験はまだしていない** [未確認]。対応するサンプルレートとフォーマットも未確認。

#### マイク（ES7210、I2S1）[実機]

- ALSA カード 1 `T-Deck Plus Microphone`、`/dev/snd/pcmC1D0c`。MIC1 と MIC3 を 16 kHz ステレオとして取る想定（TDM 4 スロット）。
- 録音の試験はまだしていない [未確認]。
- `/dev/snd/*` は `root:root 600`。root 以外で動かすアプリは権限に注意。

#### GPS [DTS]

UART0 の `/dev/ttyS0`、9600 bps。NMEA が流れる想定 [未確認]。UART0 はこのために、コンソールには使っていない。

#### 対応していないもの

| 機能 | 状態 |
|---|---|
| SD カード | `CONFIG_MMC`/`MMC_SPI`/`BLOCK`/`VFAT` が無効、CS は非選択に固定。使うにはカーネルの再ビルドと DTS の変更が要る |
| LoRa | ドライバ無し、CS は非選択に固定 |
| バッテリー電圧と充電状態 | ADC ドライバ無し。読めない |
| LCD の明るさ | GPIO 固定で、PWM が無い |
| USB ホスト | `CONFIG_USB_SUPPORT` が無効 |

---

## 3. ソフトウェア

### 3.1 カーネル [設定]

| 項目 | 値 |
|---|---|
| バージョン | 7.2.4-forkbank（上流 linux-esp32s3 ＋ このリポジトリのパッチ） |
| 構成 | `esp32s3-t-deck-plus` DTB を内蔵、XIP、NOMMU、UP、`PREEMPT_NONE`、`NO_HZ_IDLE` |
| 起動引数 | `console=tty0 console=ttyGS3 fbcon=font:VGA8x16 rw root=mtd:rootfs rootfstype=cramfs panic=10 panic_console_replay` [実機] |
| fork | forkbank バックエンド（プロセス切り替えのたびに私有メモリを入れ替える）。CoW 無し、プロセス間のメモリ保護無し |
| 内蔵フォント | VGA8x16（起動時）。`consolefont` が 8x16、8x8、7x14、6x11 を KDFONTOP で入れ替える |
| ビルド | `build-scripts\wsl-run-t-deck-plus.sh` → `kernel-work\out\xipImage-t-deck-plus`（4 MiB 以内であることを確認する） |

アプリに影響する**無効な機能**（ソースが要求したら、代わりを使う）:

| 無効 | 代わり |
|---|---|
| `EPOLL` | `poll()` / `select()` |
| `TIMERFD`、`SIGNALFD` | `poll()` のタイムアウト、self-pipe、`sigaction` |
| `INOTIFY_USER`、`DNOTIFY` | 定期的に `stat()` |
| `AIO`、`IO_URING` | 普通の `read`/`write` |
| `IPV6`、`NETFILTER` | IPv4 のみ。ファイアウォールは無い |
| `BLOCK`、`MMC`、`VFAT`、`NFS` | ファイルシステムは jffs2、cramfs、tmpfs だけ |
| `USB_SUPPORT`、`HID`、`INPUT_MOUSE` | 入力は §2.6 の機器だけ |
| `DEVMEM` | `/dev/mem` は無い。レジスタは `espctl` かカーネルドライバで |
| `LEGACY_TIOCSTI` | 端末への文字の差し込みはできない |
| `KALLSYMS`、`PERF_EVENTS`、`FTRACE`、`DEBUG_FS` | カーネル側のトレースはできない |
| `RFKILL` | wpa_supplicant が `rfkill` の警告を出すが問題ない |

有効なもの: `CFG80211`、`PACKET`、`UNIX`、`INET`、`I2C_CHARDEV`、`GPIO_SYSFS`、`SPI`、`INPUT_EVDEV`、`SND_SOC`、`FB` と `FRAMEBUFFER_CONSOLE`（回転あり）、`VT`、`MAGIC_SYSRQ`、`HW_RANDOM_ESP32`、`CONSOLE_TRANSLATIONS`。

### 3.2 起動の流れとサービス [実機]

1. ROM → 2nd ブートローダ → Core 0 ファーム → Core 1 で Linux（XIP）
2. busybox `init`。cramfs 側の `inittab` で sysinit（`mount -a` で `/etc`、`/home` の jffs2 が重なる）
3. `/etc/init.d/S??*`: `S03keepconfig`（設定の退避と復元）、syslogd/klogd、sysctl、`S40network`（バックグラウンド、ログは `/var/log/network.log`）、`S45inetd`（dropbear をここから起動）、`S46blewifi`、`S47usbconsole`、ntpd、`S99tdeck-console`
4. `S99tdeck-console`: jffs2 側の `/etc/inittab` に `tty1::respawn:/sbin/getty -L tty1 0 linux` を足し、キーボードバックライトとフォントを戻し、`dmesg -n 4`、`kill -HUP 1` で inittab を読み直させ、`chvt 1`
5. LCD の tty1 にログインプロンプトが出る。root は bash（`-l`）。`/etc/profile.d/tdeckctl.sh` あり
6. 時計: 電池で動く RTC は無い。シャットダウン時に保存した時刻を戻し（"Clock restored ... saved at shutdown"）、ntpd で合わせる。**Wi-Fi が無いと時刻は正しくない**（TLS の証明書確認に影響する）

### 3.3 ファイルシステムと書ける場所 [実機]

| マウント | 種類 | 大きさ / 空き（目安） | 用途 |
|---|---|---|---|
| `/` | cramfs（読み取り専用、XIP） | 7.0 MB / 0 | 変更できない。変えるにはイメージを作り直す |
| `/etc` | jffs2 | 448 KB / 約 200 KB | 設定。`/etc/inittab`、`/etc/network/interfaces`、`/etc/wpa_supplicant.conf` |
| `/home` | jffs2 | 3.3 MB / 約 2.1 MB | **アプリの置き場所**。`/home/bin`、`/home/lib`、`/home/<アプリ名>` |
| `/tmp`、`/run`、`/dev/shm` | tmpfs | **RAM を使う** | 一時ファイルだけ。大きなものは置かない |

- 全体を書き込む（フルイメージを焼く）と `/etc` と `/home` が初期化される。`S03keepconfig` が引き継ぐのは `wpa_supplicant.conf`、`shadow`、`passwd`、`group`、`inetd.conf`、`remote-login*` だけで、`inittab` と `network/interfaces` は戻らない。このボードでは**カーネルパーティションだけ**を書く運用にしている（§4.10）。
- jffs2 への書き込みは遅い（上流の計測で 43〜50 KB/s）。ログを頻繁に書くなら `/run` に。

### 3.4 ユーザーランド

#### 主なコマンド

| 種類 | 内容 |
|---|---|
| シェル | bash 5.2.37（ログインシェル、readline）、dash、busybox ash（`/bin/sh` → busybox） |
| 基本 | busybox（coreutils 相当、`vi`、`ip`、`udhcpc`、`ntpd`、`nslookup`、`base64`、`gzip`/`gunzip`、`setsid`、`killall`、`pidof`、`chvt`、`stty`、`od`、`dd` など）。`file`、`locale`、`pgrep` は無い [実機] |
| 上流の同梱 | MicroPython（`posix` で fork、ソケット）、GNU Make、cron、dtach（`session`）、nano、curl（HTTPS は実験的）、socat、nc、`espctl`（GPIO/I2C）、`remote-login`、`web-server`、`usb-console` |
| ネットワーク | `wifi`（`/usr/bin/wifi`）、`wpa_supplicant` 2.11（PSK のみ。EAP 無し、制御ソケット無し → `wpa_cli` は使えない）、`iw`、`ble-wifi-setup`、dropbear 2024.85（サーバーと `dbclient`）。SFTP は無い（`scp -O` を使う） |
| 無いもの | `aplay`/`arecord`（alsa-utils）、python3、gcc、`strace`、`gdb` |

#### このボード用に `/home/bin` に入れたもの

| パス | 内容 | ソース |
|---|---|---|
| `tdeckctl` | 設定 TUI（Wi-Fi、キーボードバックライト、音声の状態、システム情報、フォント） | `tools\tdeckctl.sh` |
| `consolefont` | KDFONTOP でフォントを入れ替える（`8x16`、`8x8`、`7x14`、`6x11`） | `build-scripts\wsl-consolefont-build.sh` |
| `evpeek` | 入力イベントを表示する（`evpeek /dev/input/eventN <件数>`） | `tools\evpeek.c` |
| `ptyrun` | PTY を割り当てて対話プログラムを動かす | `tools\ptyrun.c` |
| `ssh` | dbclient のラッパー。`ssh sakura`、`ssh desktop` を展開し、`TERM=linux` を固定 | （実機上のみ） |
| `htop`（`htop.bin` ＋ ラッパー） | htop 3.5.3。`/home/lib/libncurses.so.6` を使う。止めるのは `killall htop.bin` | `HTOP.md` |
| `fastfetch` | 構成を固定した版 | `SCREEN.md` |

設定の保存先: `/home/tdeck/`（`console-font`、`keyboard-backlight`、`keyboard-backlight-default`、mode 600）。

#### ライブラリ [実機]

`/lib`: `ld-uClibc-1.0.48.so`（`ld-uClibc.so.0/.1`）、`libuClibc-1.0.48.so`（`libc.so.0/.1`）、`libatomic.so.1`、`libgcc_s.so.1`。
`/usr/lib`: `libnl-3.so.200`、`libnl-genl-3.so.200`（3.2.27 系）。ほかに上流の rootfs が持つもの（ncurses など）は実機で一覧を取ってから使うこと [未確認]。
**OpenSSL と alsa-lib は rootfs に無い**（wpa_supplicant も internal TLS を前提にする必要があった）。

#### terminfo [実機]

`/usr/share/terminfo`: `ansi`、`dumb`、`linux`、`putty`、`putty-256color`、`putty-vt100`、`screen`、`screen-256color`、`vt100`、`vt100-putty`、`vt102`、`vt200`、`vt220`、`xterm`、`xterm+256color`、`xterm-256color`、`xterm-color`、`xterm-xfree86`。

### 3.5 ネットワーク

- インターフェースは `espsta0` だけ（STA のみ。AP にはなれない）。IPv4、DHCP（`udhcpc`、ホスト名 `esp32s3`）。
- Wi-Fi の設定は `/etc/wpa_supplicant.conf`。`wifi`、`wifi scan [--tsv]`、`wifi connect "SSID" [PW]`、`wifi status`、`wifi disconnect`。スマホから BLE（Nordic UART）でも設定できる（`BLE.md`）。
- 対応: オープンと WPA2-PSK [実機]。WPA3-SAE は未検証。**802.1X（Enterprise）は非対応**。EAP 版 wpa_supplicant を試したが、RAM が足りず取りやめた。そのときも、802.1X の AP では 802.11 の認証段階で `reason=201` になり、EAP の交換まで進まなかった（2026-11-17）。
- 既知の問題: 再起動後に DHCP の Offer が来ないことがあった（`HTOP.md`。原因は未特定）。
- リモートログイン: inetd → dropbear（ポートと認証方式は `remote-login`）。接続がないときは dropbear は動いていない。
- 外向きの SSH: `ssh` ラッパー（dbclient は `~/.ssh/config` を読まない）。鍵は **Dropbear 形式**（`*_db`）にすること。dbclient は OpenSSH 形式の ed25519 鍵を読めない（"String too long"）。known_hosts は `/home/root/.ssh/known_hosts`。

### 3.6 コンソールと端末

| tty | 実体 | TERM | 大きさ |
|---|---|---|---|
| tty1 | LCD（fbcon）。getty → bash | `linux` | 6x11 フォントで **53 列 × 21 行**（既定）。8x16: 40×15、8x8: 40×30、7x14: 45×17 [実機] |
| `/dev/console`（ttyGS3） | USB シリアル。PC 側 COM24、115200 | `vt100` | 決まった大きさなし（`stty size` は不定） |
| pty | SSH ログイン（dropbear） | 接続元しだい | 接続元しだい |

### 3.7 文字の表示（日本語と罫線）

- VT は **UTF-8 モードが既定**（`default_utf8 = true`、`CONFIG_CONSOLE_TRANSLATIONS=y`）[ソース]。UTF-8 の文字は、Unicode からフォント位置への対応表（既定は CP437）で引かれる。
- 内蔵の 4 つのフォントは、どれも **CP437 の並び**（`0xC4` = `─`、`0xB3` = `│` など）[ソース]。そのため、**罫線（`─│┌┐└┘├┤┬┴┼` と二重線）、ブロック（`█▄▀░▒▓`）、一部の記号とラテン文字は表示できる**。ただし実機の画面ではまだ確かめていない [未確認]。
- 表示できないもの: CP437 に無い文字。たとえば `⏺ ✻ ❯ ✓ ✗ …`、点字の回転表示（`⠋⠙…`）、絵文字、全角文字。これらは代わりの文字か空白になり、**幅の計算がずれて画面が崩れる**原因になる。
- **日本語は表示できない。** VT のフォントは KDFONTOP で最大 512 グリフ（`max_font_glyphs = 512`）[ソース]、文字の幅も 1 セル固定で、CJK の数千字と全角幅を入れられない。日本語を出すには、フレームバッファに直接描く端末エミュレータ（自前の描画、またはクロスビルドした fbterm 系）と CJK フォントが必要。その場合は RAM を大きく使う。
- アプリ側の指針: 文字の出力は **ASCII と CP437 の範囲**に限る。`TERM=linux` を使う（16 色。256 色や true color は使わない）。53 列で崩れないレイアウトにする。

> 訂正（2026-11-19）: 以前の会話で「`CONFIG_UNICODE` が無効なので UTF-8 を解釈しない」と説明したが、誤り。`CONFIG_UNICODE` はファイルシステムの UTF-8 正規化用で、VT とは関係ない。

---

## 4. アプリ開発ガイド

### 4.1 ツールチェーン（WSL）

| 項目 | 値 |
|---|---|
| ホスト | WSL Ubuntu 24.04（**aarch64**）、ユーザー `builder` |
| コンパイラ | `~/esp32s3/build/crosstool-NG/builds/xtensa-esp32s3-linux-uclibcfdpic/bin/xtensa-esp32s3-linux-uclibcfdpic-gcc`（GCC 14.1.0） |
| 必須の環境変数 | `XTENSA_GNU_CONFIG=~/esp32s3/build/xtensa-dynconfig/esp32s3.so` |
| CFLAGS | `-Os -mfdpic -mauto-litpools -fPIC -ffunction-sections -fdata-sections` |
| LDFLAGS | `-Wl,--gc-sections -Wl,--hash-style=sysv -Wl,-z,stack-size=131072`（スタックは用途に合わせる。64 KiB〜128 KiB） |
| strip | `xtensa-...-strip --strip-unneeded -R .xt.prop -R .xt.lit` |

最小の例（`build-scripts\wsl-evpeek-build.sh` と同じ形）:

```bash
#!/usr/bin/env bash
set -euo pipefail
B=$HOME/esp32s3/build
host=xtensa-esp32s3-linux-uclibcfdpic
P=$B/crosstool-NG/builds/$host/bin/$host
export XTENSA_GNU_CONFIG=$B/xtensa-dynconfig/esp32s3.so
"$P-gcc" -std=c99 -Os -mfdpic -mauto-litpools -fPIC -ffunction-sections -fdata-sections \
    -Wall -Wextra -Wl,--gc-sections,--hash-style=sysv,-z,stack-size=131072 \
    -o out/myapp myapp.c
"$P-strip" --strip-unneeded -R .xt.prop -R .xt.lit out/myapp
"$P-readelf" -l out/myapp | grep LOAD     # 最初の LOAD（R E）が 262144 以下か確かめる
"$P-readelf" -d out/myapp | grep NEEDED   # 実機にあるライブラリだけか確かめる
```

注意:

- **ホストが aarch64 なので、`cc` や `gcc` をそのまま呼ぶとホスト用（ARM）のバイナリができる。** autoconf では `--host=xtensa-esp32s3-linux-uclibcfdpic` を付けて PATH にクロスの bin を入れ、`CC` を明示する。make では `export CC=...-gcc` にする（コマンドラインの `CFLAGS=` は makefile の `+=` を潰す）。
- PowerShell から `wsl ... bash -lc "...$VAR..."` とすると `$` が PowerShell 側で展開される。**スクリプトファイルにして** `wsl -d Ubuntu -u builder -- bash /mnt/c/.../x.sh` で動かす。
- 実機のライブラリは sstrip 済みで、そのままではリンクに使えない。リンク用のライブラリは同じ版をソースからビルドする（`HTOP.md`）。
- uClibc-ng で足りないもの: `fork()` の宣言、`getifaddrs()`、`<uchar.h>` など。移植のときに出たものは `HTOP.md` と `SCREEN.md` に記録がある。

### 4.2 NOMMU の制約（最重要）

1. **コード領域は 256 KiB 以下にする。** 実行ファイルの最初の `LOAD`（R E）は、2 のべき乗に切り上げた**連続した RAM ブロック**にコピーされる。262,144 バイトを 1 バイトでも超えると 512 KiB のブロックが要り、しばらく動かしたボードでは確保できずに起動しなくなる（`nommu: Allocation of length ... failed`）。
   - 空いているブロックは `cat /proc/buddyinfo`（左から 7 列目が 256 KiB、8 列目が 512 KiB の数）で見る。
   - 大きくなるときの対策: `-Os`、`--gc-sections`、`--hash-style=sysv`、機能を削る、共有ライブラリに分ける。
   - 常駐させるなら、起動直後に 1 回だけ起動して、作り直さない（wpa_supplicant 830 KB 版は SIGHUP で設定を読み直させる案を取った）。
2. **プロセスを 1 つ起こすたびに、スタック用の連続 64 KiB が要る。** シェルスクリプトで `sed`、`grep`、`awk` を何本も起こすと失敗しやすい（`nommu: Allocation of length 65536 ... failed` は実機でよく出る）。**常駐する 1 プロセスに処理をまとめる**（`screend` の設計、`SCREEN.md`）。
3. **スタックのガードページが無い。** あふれても黙って隣を壊す。`-z stack-size` を明示し、大きな配列を自動変数にしない。ash の変数に大きな出力を入れない（一時ファイルを使う）。
4. **fork は特別な実装。** forkbank はプロセス切り替えのたびにメモリを入れ替える（1 回 5〜10 ms）。子プロセスを起こすだけなら `vfork()` ＋ `exec`。マルチスレッドのプロセスは fork できない。`libfork.so.0` を `/home/lib` に置いた版は FDPIC のローダーが解決できなかったので、htop は `fork-compat.c` を静的にリンクしている。
5. **メモリ保護も CoW も無い。** 不正なポインタは他のプロセスやカーネルを壊すことがある。サニタイザ付きのテストは PC 上でネイティブにビルドして行う（`build-scripts\wsl-screend-test.sh` の流儀）。
6. **`/proc/PID/statm` の値は当てにならない**（4093M のように出る）。メモリは `/proc/meminfo` の `MemAvailable` で見る。
7. CPU は Linux 用に 1 つ（240 MHz）。htop を 0.5 秒周期で動かすと CPU の 40% を使った。描画やポーリングの周期は控えめにする。

メモリ予算の目安: `MemAvailable` 2.0〜2.6 MB から、bash の SSH 1 本、htop 1 本などを引く。**アプリ 1 本で 1 MB 以下**を目標にする。

### 4.3 画面に出す

**A. テキスト（tty1）** — いちばん簡単。

- `TERM=linux`、53×21（`ioctl(TIOCGWINSZ)` で取る。フォントを変えると変わる）。ANSI の 16 色と CP437 の文字（§3.7）。
- 自分で起動するとき: `setsid -c env TERM=linux /home/bin/myapp < /dev/tty1 > /dev/tty1 2>&1`（`HTOP.md`）。tty1 には getty がいるので、取り合いに注意。
- 消灯を止める: `printf '\033[9;0]' > /dev/tty1`。
- curses を使うなら、`/home/lib` の `libncurses.so.6`（ワイド文字なし）を htop と同じく `LD_LIBRARY_PATH` で使う。

**B. フレームバッファに直接（`/dev/fb0`）**

- 320×240、RGB565 LE、1 行 640 バイト、合計 153,600 バイト。`lseek` ＋ `write` で書ける（`cat image.rgb565 > /dev/fb0` は動いた）。NOMMU での `mmap` は未検証 [未確認]。
- fbcon がカーソルや文字を上から描くので、描画中は `ioctl(fd_tty, KDSETMODE, KD_GRAPHICS)` にして、終わったら `KD_TEXT` に戻す [未確認]。
- 画面の確認: `dd if=/dev/fb0 of=/run/fb.raw bs=1 count=153600` を取り出し、`py -I tools\fb_snapshot.py fb.raw out.png --size 320x240`。
- フレームバッファの全体を何度も送り直すと、SPI の転送と CPU を食う。変わったところだけ書く。

### 4.4 入力を読む

- evdev（`/dev/input/eventN`、`struct input_event`）。デバイスは名前で探す:

```sh
for f in /sys/class/input/input*/name; do echo "$f: $(cat "$f")"; done
```

- キーボード: `EV_KEY`。1 回の押下につき、押下と離しのペアがすぐに来る（押しっぱなしの検出はできない。Mic の Ctrl だけは押している間ずっと押下になる）。キーリピートは無い [未確認]。
- トラックボール: `KEY_UP/DOWN/LEFT/RIGHT`、`KEY_ENTER`。
- タッチ: `EV_ABS`（`ABS_MT_POSITION_X/Y`）。座標の変換は §2.6 の注意を参照。
- テキストアプリなら、tty1 から普通に `read()` してもよい（キーボードは VT のキーマップ経由で ASCII になる。US 配列）。
- `poll()` で複数のデバイスを待つ（`epoll` は無い）。

### 4.5 音を出す・録る

- `/dev/snd/pcmC0D0p`（再生）、`/dev/snd/pcmC1D0c`（録音）、`controlC0/C1`、`timer`。
- alsa-lib と alsa-utils は無い。カーネルの ALSA ioctl（`SNDRV_PCM_IOCTL_HW_PARAMS` など）を直接使うか、tinyalsa 程度の小さなライブラリをクロスビルドして `/home/lib` に置く。
- 対応するフォーマットとレートは、最初に `HW_REFINE` で調べること [未確認]。

### 4.6 そのほかの機器

| 機器 | 使い方 |
|---|---|
| GPS | `/dev/ttyS0` を 9600 8N1 で開き、NMEA を読む [未確認] |
| キーボードバックライト | `echo 128 > /sys/bus/i2c/devices/0-0055/keyboard_backlight`。保存するなら `/home/tdeck/keyboard-backlight` |
| I2C を直接 | `/dev/i2c-0`（`I2C_SLAVE` ioctl）。`0x55` を触るとキーボードドライバとぶつかる |
| GPIO | `/sys/class/gpio`（sysfs）。gpio-hog と各ドライバが使う線は取れない。`espctl` もある |
| 乱数 | `/dev/hwrng`、`/dev/urandom` |

### 4.7 アプリの置き場所と自動起動

- 実行ファイルは `/home/bin/<名前>`（PATH の先頭）、ライブラリは `/home/lib`、データと設定は `/home/<アプリ名>/`（秘密の情報は mode 600）。
- 起動時に動かすなら、`/etc/init.d/S9x<名前>` を追加するか、`/etc/inittab` に `respawn` の行を足す（`kill -HUP 1` で読み直す）。`/etc/inittab` と `/etc/init.d` は全体の書き込みで消えるので、元に戻す手順も用意しておく。
- 落ちたときに暴走して起こし直されないよう、ランチャで待ち時間を入れる（htop-launch は、5 秒以内に終わったら 10 秒待つ）。

### 4.8 実機に送る

- SSH が使えるとき: `scp -O file root@<IP>:/home/bin/`（SFTP サーバーは無い）。
- シリアルだけのとき: `tools\ttyshell.py` で base64 を 1000 文字ずつ `printf '%s' '...' >> /run/x.b64` で送り、`base64 -d` で戻す。**ヒアドキュメントは使えない**（ttyshell が各行の末尾に `; echo "[[END:$?]]"` を付けるため）。大きいものは先に gzip（実機に `gunzip` あり）。送ったら `sha256sum` で比べる。
- **改行は LF にする。** Windows でテキストモードのまま書くと CRLF になり、`#!/bin/sh\r` のせいで「cannot execute: required file not found」になる（2026-11-17 に tdeckctl で起きた）。Python なら `write_bytes` か `newline="\n"`。
- 送ったら `chmod 755`。

### 4.9 カーネルやドライバを変えるとき

- 編集は `kernel-work\overlay\`、設定は `kernel-work\config\t-deck-plus.config`。
- コンパイルの確認だけなら `build-scripts\wsl-check-t-deck-plus.sh`。イメージを作るのは `wsl-run-t-deck-plus.sh`。
- 書き込むのは **`linux` パーティション（`0x140000`、4 MiB）だけ**。先に `backup\` のフルバックアップがあることを確かめる。フル書き込みの道具は使わない（`/etc` と `/home` を書き換える）。
- 音声のための DMA の予約はファーム側と対になっている。`CONFIG_VECTORS_ADDR` はファームの `space_for_vectors` と一致させる（`T-DECK-PLUS.md`）。

### 4.10 作るときの確認表

- [ ] 最初の `LOAD`（R E）が 262,144 バイト以下
- [ ] `NEEDED` が実機にあるライブラリだけ（`libc.so.0`、`/home/lib` に置くもの）
- [ ] `-z stack-size` を明示した
- [ ] `fork` を使わない、または `vfork` ＋ `exec` にした。スレッドと fork を混ぜない
- [ ] `epoll`、`timerfd`、`inotify`、IPv6 を使っていない
- [ ] 常駐 1 プロセスで、外部コマンドをループで起こさない
- [ ] 出力は ASCII と CP437 だけ、53×21 に収まる、`TERM=linux`
- [ ] 書き込みは `/home`、一時ファイルは `/run` で、どちらも小さい
- [ ] スクリプトは LF 改行
- [ ] 起動直後と、しばらく動かしたあと（断片化した状態）の両方で起動を試した

---

## 5. 既知の問題

| 問題 | 内容 |
|---|---|
| `nommu: Allocation of length 65536 ... failed` | プロセスを起こすときの連続領域不足。たいていは一時的で、その 1 本が失敗するだけ。多いときは再起動 |
| `WARNING: net/wireless/core.h:230` | 起動後しばらくして出る esp-hosted の警告。動作に影響しない |
| `esp32_wifi:cmd_scan_request ... failure` | 起動直後のスキャンで出ることがある。しばらくすると回復 |
| 802.1X の AP に接続できない | §3.5 |
| DHCP の Offer が来ない | 再起動後にまれに起きる。USB シリアルから静的 IP で回復（`tools\serial_static_ip.cmds`） |
| SSH 先の claude/opencode の表示が崩れる | 幅 53 列、CP437 に無い文字、256 色の前提（§3.7）。ラッパーで `TERM=linux` を固定済み |
| 時刻がずれる | RTC が無い。ネットワークが無いと NTP が効かない |

## 6. 主な参照ファイル

| ファイル | 内容 |
|---|---|
| `kernel-work\overlay\arch\xtensa\boot\dts\esp32s3-t-deck-plus.dts` | 配線（この文書の §2 の元） |
| `kernel-work\overlay\drivers\input\keyboard\tdeck-keyboard.c` | キーボードドライバとプロトコル |
| `kernel-work\config\t-deck-plus.config` | カーネル設定の差分 |
| `tools\tdeckctl.sh`、`tools\tdeck-console-init.sh` | TUI と起動フック |
| `tools\evpeek.c`、`tools\ptyrun.c` | 入力と PTY の小さな C の例 |
| `tools\ttyshell.py`、`tools\fb_snapshot.py` | シリアル操作と画面の取り込み |
| `build-scripts\wsl-*.sh` | 各ビルド手順（`wsl-evpeek-build.sh` が最小の例） |
| `build-output\t-deck-plus-*\` | 書き込み計画、チェックサム、シリアルログ |

## 7. 実機をつないだら確かめること

この文書の **[未確認]** のうち、アプリの設計に効くもの:

1. 罫線と CP437 の文字が、tty1 で実際に正しく出るか（`printf '\342\224\200\342\224\202\342\224\214\n' > /dev/tty1`）
2. タッチの座標が画面の向きと一致するか（`evpeek` で四隅を押す）
3. 入力デバイスの番号と名前（`/proc/bus/input/devices`）
4. `/usr/lib` のライブラリ一覧（ncurses の有無と版）と busybox のアプレット一覧
5. スピーカーとマイクのフォーマットとレート（小さな ALSA の試験プログラムで）
6. `/dev/fb0` の `mmap` が使えるか、`KD_GRAPHICS` で fbcon が止まるか
7. GPS の出力（`cat /dev/ttyS0`）
