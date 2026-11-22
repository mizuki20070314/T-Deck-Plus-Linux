# 画面をブラウザから切り替える／fastfetch（記録）

2026-10-31。ボードの丸い画面（AMOLED コンソール）に出す内容を、ブラウザの管理画面から切り替えられるようにした。
あわせて、htop の更新を 0.5 秒にし、fastfetch を移植した。

## 使い方

| 項目 | 内容 |
|---|---|
| 管理画面 | `http://192.168.0.8:8080/`（ユーザー `admin`、パスワードは PC の `secrets\screen-admin-password.txt`） |
| 入れる・更新する | `powershell -File C:\Users\mizuk\esp32s3-linux\tools\screen_install.ps1` |
| パスワードを変える | `... screen_install.ps1 -NewPassword` |
| 状態を見る | `... screen_install.ps1 -Status` |
| 外す（htop を `htop-launch` に戻す） | `... screen_install.ps1 -Uninstall` |
| 実機の SSH から | `screend ctl mode htop｜fastfetch｜text｜blank`、`screend ctl refresh`、`screend ctl bright 0〜255`、`screend ctl text '文字'`（`\n` は改行）、`screend ctl status` |

管理画面でできること:

- **表示する内容**: htop／fastfetch／テキスト／消灯（黒い画面）。切り替えは 1〜5 秒で反映される。
- **いまの画面**: ボードのフレームバッファを読んで、丸いガラスの形で見せる（3 秒ごとに自動更新、止められる）。
- **テキスト**: 好きな文字を出す（半角の英数字と記号だけ。コンソールのフォントに日本語が無いため）。
- **明るさ**: 0〜255。
- **ボードの状態**: 稼働時間、メモリ、負荷平均。

選んだ内容と明るさは `/home/screen/` に保存され、再起動後も同じものが出る。

## 仕組み

```
ブラウザ ──HTTP(8080)──▶ screend（root、常駐する1プロセス）──▶ tty1（htop／fastfetch／テキスト／黒）
                           ├ /home/screen/ : index.html、auth（ログイン）、mode・text・brightness
SSH ── screend ctl … ──Unixソケット──▶ ┘
```

`screend`（`tools\screend\screend.c`、約 800 行の C、26KB）が、画面の管理・Web ページの配信・API・ログイン・フレームバッファの配信を **1 つのプロセス** で行う。
起動は `init`（`/etc/inittab` の `tty1::respawn:/home/bin/screend`）。落ちても `init` が起こす。

### なぜ busybox の httpd と CGI にしなかったか

最初はそう作った（シェルの管理プログラムと、`www-data` で動く CGI）。ところが試験でボードが止まった。

- この板は MMU が無く、RAM が 7.8MB で、**プロセスを 1 つ起こすたびに、スタックとして 64KB の連続した RAM が 1 つ要る**。
- ページが 3 秒ごとに状態とプレビューを取りに来ると、1 回のリクエストで httpd、CGI のシェル、`sed`・`head`・`tr` などを何本も起こす。連続領域が尽きて（`nommu: Allocation of length 65536 … failed`）、`inetd` が SSH も起こせなくなり、ハードリセットが要った。

常駐する 1 プロセスなら、リクエストはプロセスを起こさない。root で直接動くので、画面や明るさの権限のための回避策も要らない。

### 安全のために

- **ログイン**: HTTP の Basic 認証。パスワードは実機に置かず、PBKDF2-SHA-256（10,000 回、塩つき）のハッシュだけを `/home/screen/auth`（root のみ読める）に置く。成功した `Authorization` はメモリに覚え、次からは再計算しない。失敗すると 0.7 秒待つ。
- **書き込みにはトークン**: 画面を変える操作は、ログインした GET の `/api/status` が返す、起動ごとのランダムなトークンを付けないと拒否する。別のサイトがブラウザに勝手に送らせることができない。
- **LAN だけ**: 接続元が private なアドレス（10/8、172.16/12、192.168/16、169.254/16、127/8、100.64/10）以外なら、何も返さずに切る。
- **入力は許可リスト**: モードは 4 つ、明るさは 0〜255 の数字、テキストは印字できる ASCII と改行だけ（ESC などの制御文字は捨てる）。シェルには何も渡さない。起動するのは固定のパスの `htop` と `fastfetch` だけ。
- **平文の HTTP**: 暗号化はしていない。家庭内の LAN で使う前提で、インターネットには出さない（ボードの README も同じ注意）。

### ファイルと場所（実機。どれもフラッシュなので再起動後も残る）

| 場所 | 内容 |
|---|---|
| `/home/bin/screend` | 本体（`tools\screend\screend.c`） |
| `/home/bin/fastfetch`、`/home/bin/htop`、`/home/bin/htoprc` | 画面に出すプログラムと htop の設定 |
| `/home/screen/index.html` | 管理画面のページ（`tools\screend\index.html`） |
| `/home/screen/auth` | ログイン（`admin:pbkdf2-sha256:回数:塩:ハッシュ`、モード 600） |
| `/home/screen/mode`、`text`、`brightness` | 選んだ内容 |
| `/run/screend.sock` | `screend ctl` 用のソケット（所有者のみ） |
| `/etc/inittab` | `tty1::respawn:/home/bin/screend`。元は `/etc/inittab.before-screen` |

`inetd.conf`、httpd、ボード付属の `web-server` には触らない（ポートは 8080 で別）。

## 画面の切り替えの挙動

- htop は走り続けるプログラム。切り替えるときは SIGTERM で止める（5 秒待っても止まらなければ SIGKILL）。止まったあとに、次の内容を出す。
- fastfetch は 0.5 秒ほどで終わるので、実行して出力を画面に残す（走り続けない）。「表示を更新し直す」で取り直す。
- htop が 5 秒もたたずに終わったとき（起動に失敗したとき）は、10 秒待って起動し直す。画面と管理画面にエラーが出る。それ以外で終わったときは 3 秒後に起動し直す。
- 画面の自動消灯はしない（`SCREEND_BLANK_MIN` で分を指定すると消える。キーボードが無いので、起こすには管理画面で内容を切り替える）。AMOLED の焼き付きに注意（HTOP.md）。

## 試験

`build-scripts\wsl-screend-test.sh` が、PC（WSL）でデーモンをネイティブに（アドレス・未定義動作のサニタイザ付きで）ビルドし、`tools\screend\test_screend.py` で試験する。偽の htop と fastfetch、ファイルの偽のコンソールとフレームバッファを使う。

- 暗号: SHA-256 の既知の値と、PBKDF2 5 ケースが Python の `hashlib` と一致。
- HTTP: ログイン（なし、誤り、正しい）、トークン、不正な値、巨大な本文とヘッダ、パス、メソッド、空の事前接続と途中で止まる接続に待たされない、Unix ソケット、htop・fastfetch の失敗、SIGTERM での後始末。

### 実機での試験（2026-10-31）

| 試験 | 結果 |
|---|---|
| インストール（`screen_install.ps1`） | 1 回で成功。ログインなしは 401、ありは 200。PC（.NET）で作った PBKDF2 のハッシュを、実機の C の実装が受け付けた |
| API（実機、PowerShell から） | 4 つのモードの切り替え、明るさ、不正なパスワード 401、トークンなしの書き込み 403。各モードの画面を `/api/fb` から画像にして確認（`htop\screend-*.png`） |
| ブラウザ操作 | 本物のボードのログインはブラウザの道具から入力できないので、**PC の WSL でネイティブ版を動かし、`localhost` に対して**行った。ボタン、強調表示、テキスト、明るさのスライダー、プレビュー（丸い形と色）が正しく動いた |
| 負荷（ページを開きっぱなしの想定） | 2 分間、3 秒ごとに状態とプレビューを取得。**リクエストのエラー 0**。状態は平均 167ms（最大 292ms）、プレビューは平均 1.3 秒（最大 4.5 秒）。`screend` の CPU は 9.5%（ほぼ全部が 210KB のプレビューの送信）。メモリの確保の失敗は、HTTP 側では無し |
| 再起動 | fastfetch を選んだまま再起動すると、`init` が `screend` をカーネル起動の約 14 秒後に起動し、選んでいた fastfetch が画面に出た（Uptime 16 秒、`htop\screend-after-reboot.png`）。ページも再起動後に応答した。メモリ確保の失敗は 0 件 |

プレビューは 1 回 210KB、ボードの CPU で約 0.3 秒かかるので、ページは 5 秒ごと（状態は 2.5 秒ごと）に取る。見ないときは「更新」のチェックを外せば止まる。

## fastfetch の移植

fastfetch 2.70.0（2026-10-14 のリリース）を、FDPIC・uClibc-ng のユーザーランド向けにクロスビルドした。実機の `/home/bin/fastfetch`（199KB）。

### 完全版は載らない

そのまま（JSON 設定とコマンドラインつきで）ビルドすると、実行ファイルは 443KB、実行コード領域は 433KB（`.text` 346KB、`.rodata` 65KB ほか）になる。NOMMU のカーネルは、この領域を 1 つの連続した RAM にコピーして実行する（`/home` の jffs2 は直接実行できない）ので、256KB 未満に収めないと、動かし続けたあとの RAM では起動できない（HTOP.md の「htop が起動しない」と同じ事情）。内訳は、JSON ライブラリ yyjson が 142KB、コマンドラインの解釈（`commandoption.c`、`fastfetch.c`、`options/*`）が約 140KB、残りが検出と整形。

### そこで、構成を固定した版にした

fastfetch 自身が「最小版」として持つ `flashfetch`（構成をコンパイル時に決める版）と同じ方式にした。`build-scripts\fastfetch-add\src\flashfetch.c` がこの板専用のフロントエンドで、41×20 の画面に合わせて、小さな Tux を上に、情報を 1 行ずつ並べる。JSON 設定とコマンドラインの解釈が要らなくなり、yyjson ごとリンクから外れる。**実行ファイルは 199KB、実行コード領域は 190,776 バイト（256KB 未満）。** 検出と整形のコードは fastfetch のものそのまま。表示を変えるには `flashfetch.c` を直してビルドし直す（JSON の設定ファイルは使えない）。

### ソースへの変更（`wsl-fastfetch-build.sh` がビルドのたびに、原本のコピーに当てる）

| 変更 | 理由 |
|---|---|
| 組み込みロゴ 531 個のうち `linux`（と小さい版）と `unknown` 以外を外す | ロゴのデータが大きい |
| `gpu_windows.c` を外す | WSL 用の GPU 検出が `<uchar.h>` を要し、uClibc-ng に無い |
| `detection/localip/localip_linux.c` を差し替え（`fastfetch-add\`） | uClibc-ng に `getifaddrs()` が無い。IPv4 を `SIOCGIFCONF` で集める版（IPv6、MAC、リンク速度は出さない） |
| `cpu_linux.c` に `cpu MHz :` の 1 行を足す | xtensa は汎用の分岐に入り、クロックを読まない。原文が想定どおりでなければビルドが失敗する |
| スレッド、Lua、zlib、画像ロゴ、各種ライブラリ（Wayland、DRM、dbus など）、使わないモジュール 60 個を無効に | RAM とサイズ |
| CMake のツールチェーンファイル `fastfetch-toolchain.cmake` | クロスビルド用 |

### ビルドの手順

```powershell
wsl -d Ubuntu -u builder -- bash /mnt/c/Users/mizuk/esp32s3-linux/build-scripts/wsl-fastfetch-fetch.sh 2.70.0   # 取得（タグのコミットを GitHub API と照合）
wsl -d Ubuntu -u builder -- bash /mnt/c/Users/mizuk/esp32s3-linux/build-scripts/wsl-fastfetch-build.sh          # ビルド（約3分）。実行コード領域が 256KB を超えるとエラー
```

成果物は WSL の `~/esp32s3/fastfetch/out/fastfetch`。Windows 側の `fastfetch\out\fastfetch` にコピーして使う（`screen_install.ps1` がここから実機に送る）。ソースの tar の SHA-256 は `8aa01bd3faff2be1…`、タグ 2.70.0 のコミットは `17bb3fd2384bd814…`。

### 実機での表示

0.3〜0.5 秒で終わる。19 行、最も長い行が 40 文字で、41×20 のコンソールと丸いガラスに収まる（`htop\screend-2-fastfetch.png`）。

```
 小さな Tux（7 行）
root@buildroot
OS: Buildroot 2024.08 xtensa
HW: Waveshare ESP32-S3-Touch-AMOLED-1.43
Kernel: 7.2.4-forkbank
Uptime: 9 mins
CPU: Xtensa LX7.0.12 @ 0.240 GHz
Memory: 5.0 MiB / 7.6 MiB (66%)
Disk: 796.0 KiB / 3.3 MiB (24%)         （/home）
IP: 192.168.0.8/24
色見本 2 行
```

## 変更点のまとめ（実機）

- `/etc/inittab` の `htop-launch` の行を `screend` の行に替えた（元の行は `-Uninstall` で戻る）。
- `/home/bin/screend`、`/home/bin/fastfetch`、`/home/screen/` を追加した。
