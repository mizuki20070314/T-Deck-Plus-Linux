# htop を ESP32-S3 Linux の画面に出す（記録）

2026-10-31。実機の AMOLED コンソール（tty1）に htop 3.5.3 を全画面で出した。Linux がネイティブに動いている様子を写真に撮るため。

## 実機の側（ユーザーランド）

| 項目 | 内容 |
|---|---|
| 実行形式 | **FDPIC**（`OS/ABI: XTENSA FDPIC`）。libc は uClibc-ng 1.0.48（`libuClibc-1.0.48.so`） |
| 共有ライブラリ | `libncurses.so.6`（6.4、ワイド文字なし）、`libfork.so.0`、`libc.so.0` が `/usr/lib`・`/lib` に既にある |
| terminfo | `/usr/share/terminfo/l/linux` がある。`TERM=linux` でよい |
| 書ける場所 | ルート（cramfs）は読み取り専用。`/home`（jffs2、約3MB空き）に置く。`/home/bin/htop` |
| その他 | CPU は1つ。`/tmp` はRAM（tmpfs）なので、大きなものは置かない |

## ビルド（WSL）

```powershell
# 1回だけ: ソースの取得（ncurses 6.4 は sha256 を固定、htop は GitHub が公開するダイジェストで確認）
wsl -d Ubuntu -u builder -- bash /mnt/c/Users/mizuk/esp32s3-linux/build-scripts/wsl-htop-fetch.sh
wsl -d Ubuntu -u builder -- bash /mnt/c/Users/mizuk/esp32s3-linux/build-scripts/wsl-htop-fetch2.sh
# ncurses（リンク用のヘッダとスタブ。約30秒）→ htop（約15秒）
wsl -d Ubuntu -u builder -- bash /mnt/c/Users/mizuk/esp32s3-linux/build-scripts/wsl-htop-build.sh ncurses
wsl -d Ubuntu -u builder -- bash /mnt/c/Users/mizuk/esp32s3-linux/build-scripts/wsl-htop-build.sh htop
```

成果物は WSL の `~/esp32s3/htop/out/htop`（Windows側には `htop\out\htop` にコピーしてある。約286KB）。

作り方のポイント（このリポジトリの `experiments/mmu-poc/programs/env.sh` と同じ流儀）:

- コンパイラは `xtensa-esp32s3-linux-uclibcfdpic-gcc`（`XTENSA_GNU_CONFIG` を設定）。フラグは `-Os -mfdpic -mauto-litpools -fPIC -ffunction-sections -fdata-sections`、リンクは `-Wl,--gc-sections,-z,stack-size=131072`。NOMMU にはガードページが無いので、スタックは小さすぎると黙って壊れる（128KBにした）。
- 実機の `libncurses.so.6.4` と `libfork.so.0` は sstrip 済み（セクションヘッダが無い）で、`ld` が読めない（`file in wrong format`）。そのため、ncurses 6.4 は Buildroot と同じ設定で自前ビルドしてリンク用に使い、`libfork.so.0` はリポジトリの `fork/fork-compat.c` から作る。実行時は実機の本物が使われる。エクスポートされるシンボルは、`tiparm_s` などの拡張を除いて一致を確認した。
- NOMMU のヘッダに `fork()` の宣言が無いので `-include .../fork/real/fork-decl.h` を使い、`libfork.so.0` をリンクする。htop が `fork()` を呼ぶのは strace と lsof の画面、systemd と OpenRC のメーターだけ。
- `-D_GNU_SOURCE` を先に渡す。`-include` で先に読み込まれた `<sys/types.h>` が、htop の `config.h` より前に feature マクロを確定させて、`struct timespec` や `dirfd` が見えなくなるため。
- `configure` には `--disable-unicode --disable-hwloc --disable-sensors --disable-capabilities --disable-delayacct --disable-affinity`、`ac_cv_file__proc_stat=yes ac_cv_file__proc_meminfo=yes`、`HTOP_NCURSES_CONFIG_SCRIPT`。
- システム行の ` @ Buildroot …`（`/etc/os-release` 由来）は、41桁に入らないので、`generic/uname.c` に `sed` で小さな変更を入れて出さないようにしてある（ビルドスクリプトが行う）。
- ストリップは `strip --strip-unneeded -R .xt.prop -R .xt.lit`（プロジェクトの他のプログラムと同じ）。
- **コード領域（最初の `LOAD`、R E）は 256KB 未満にする。** NOMMU は、これを1つの連続した RAM ブロックにコピーして実行する（`/home` の jffs2 は直接実行できない）。ブロックはページ数を2のべき乗に切り上げた大きさなので、262,144 バイトを1バイトでも超えると 512KB のブロックが要る。リンクに `-Wl,--hash-style=sysv` を足して `.gnu.hash`（3.6KB）を外すと 258,828 バイトに収まる。ビルドスクリプトは、256KB を超えるとエラーで止まる（下の「htop が起動しないとき」）。

## 実機に送って画面に出す

```powershell
powershell -File C:\Users\mizuk\esp32s3-linux\tools\htop_show.ps1 -Install   # htop も /home/bin に送る（初回、または作り直したとき）
powershell -File C:\Users\mizuk\esp32s3-linux\tools\htop_show.ps1            # 再起動後などは、これだけでよい
```

`htop_show.ps1` は `htop_start.sh` と `htoprc` を実機の `/tmp` に送り、`htop_start.sh` が次を行う。

1. 動いている htop を止める。`htoprc` を `/home/root/.config/htop/htoprc` に置く。
2. `printf '\033[9;0]' > /dev/tty1`（画面の自動消灯を止める）、画面を消す。
3. `setsid -c env TERM=linux HOME=/home/root /home/bin/htop < /dev/tty1 > /dev/tty1` で、tty1 を制御端末とする新しいセッションで起動する。

そのあと `fb_snapshot.ps1 -Round` で、円形ガラスで見える範囲のPNGを `htop\snapshot-round.png` に作る（私が画面を確かめる手段）。
止めるには `ssh root@192.168.0.8 killall htop`。

## 設定（`tools\htoprc`）

41×20 の画面に合わせてある。

- ヘッダは1列（`header_layout=one_100`）: `System`（カーネルのバージョンとアーキテクチャ）、CPU、Mem、Tasks、Load average、Uptime。Swap は無いので出さない。
- ファンクションバーとタブは出さない（`hide_function_bar=2`、`screen_tabs=0`）。行が足りない。
- 列は `PID S CPU% TIME+ Command` だけ。**VIRT / RES / MEM% は出さない**: NOMMU の `/proc/PID/statm` は、メモリの大きさではない値を返し、`4093M`（RAM は 7.6MB）のように出る。メモリは Mem メーター（`/proc/meminfo` 由来）で見る。
- ツリー表示で PID 順（`init` の下に常駐プロセス、`kthreadd` の下にカーネルスレッド）。カーネルスレッドも出す。
- 更新は0.5秒（`delay=5`、2026-10-31 に2秒から変更）。htop は1回の走査に約0.3秒かかり、そのあとで設定の間隔だけ待つので、実際の周期は約0.8秒になる（パネルの更新は毎秒1.2回）。実測では、2秒（`delay=20`）のとき htop が CPU の約15%、全体で約22%、`delay=5` のとき htop が約40%、全体で約47%。SSH 1回の往復は約2.5秒から約3.2秒に遅くなった。周期を本当に0.5秒にするなら `delay` をさらに下げることになるが、その分 CPU を食う（1つしかない）。

## 起動時に自動で表示する（2026-10-31）

電源を入れる（再起動する）と、Linux が立ち上がったあと自動で htop が tty1（AMOLED）に出る。

**2026-10-31 以降は、画面の管理を `screend`（ブラウザから htop・fastfetch・テキスト・消灯を切り替えられる）に任せている。`SCREEN.md` を参照。** `screend` を入れると、この節の `htop-launch` の行は `screend` の行に替わる（`screen_install.ps1 -Uninstall` で、この節の方式に戻る）。以下は、`screend` を入れていないときの方式。

```powershell
powershell -File C:\Users\mizuk\esp32s3-linux\tools\htop_autostart.ps1 -Enable    # 入れる（今すぐ出て、次の起動からも出る）
powershell -File C:\Users\mizuk\esp32s3-linux\tools\htop_autostart.ps1 -Disable   # 外す
powershell -File C:\Users\mizuk\esp32s3-linux\tools\htop_autostart.ps1            # 状態を見る
```

実機に置かれるもの（どれもフラッシュなので再起動後も残る）:

| 場所 | 内容 |
|---|---|
| `/etc/inittab`（jffs2） | `tty1::respawn:/home/bin/htop-launch` の1行（上にコメント1行）。ttyGS3 の getty の次に入る |
| `/home/bin/htop-launch` | `tools\htop_launch.sh`。`TERM=linux`、`HOME=/home/root`、`HTOPRC=/home/bin/htoprc` を設定し、消灯の設定をして画面を消してから htop を動かす。htop が終わると3秒待って終わるので、`init` がもう一度起こす（落ちても暴走せず、`killall htop` でも作り直される） |
| `/home/bin/htoprc` | 起動時の htop の設定（`tools\htoprc`）。SSH で手で動かす htop の設定（`/home/root/.config/htop/htoprc`）とは別 |
| `/etc/inittab.before-htop` | 元の inittab。PC側にも `backup\board-etc-inittab-before-htop-autostart` |

仕組み:

- 実機の `init`（busybox）は、起動時には読み取り専用の cramfs 側の inittab しか見えない（jffs2 の `/etc` は sysinit の `mount -a` で後から重なる）。`/etc/init.d/S47usbconsole` が「`/etc/inittab` に `ttyGS3::` があれば `kill -HUP 1`」で読み直させていて、そのとき jffs2 側の `tty1::respawn:` も拾われる。`-Enable` が最後に流す `kill -HUP 1` も同じ手で、再起動しなくても今すぐ起動する。この S47 の仕組みや inittab の ttyGS3 の行を外すと、この行も効かなくなる。
- 起動の流れ: カーネルが起動 → `init` → rcS（S47 まで） → inittab の読み直し → `htop-launch` → htop。実測で、`htop-launch` はカーネルの起動から約12〜13秒後に始まる（2回計測。ブートローダ分は別）。
- inittab の書き換えは、隣に新しいファイルを作り、追加した2行を除くと元とバイト単位で一致することを確かめてから rename する。
- 自動起動が有効なとき、`htop_show.ps1` は設定を `/home/bin/htoprc` に送って htop を止めるだけにする（`init` が起こす）。手で別の htop を起動すると tty1 を取り合うため。`-Install`（htop 本体の入れ替え）は、隣に置いてから rename するので、htop が動いていても入れ替えられる。

注意:

- 消灯しない設定にしてあり、輝度は最大（255）のまま。AMOLED は同じ絵を何か月も出し続けると焼き付く。出しっぱなしにするなら、`htop_launch.sh` の `BLANK_MIN`（消灯までの分）を `10` などにして `-Enable` をもう一度流し、`htop_show.ps1` で htop を起こし直す。キーボードが無いので、消灯した画面は SSH から `printf '\033[9;10]' > /dev/tty1` で起こす（`ESC [ 9 ; n ]` は消灯時間を決めて、同時に画面を起こす。`vt.c` で確認）。明るさは `echo 80 > /sys/bus/spi/devices/spi0.0/brightness`。
- htop は常に CPU を15〜20%使い、`MemAvailable` は約1.8MB に下がる（SSH を1本つないだ状態）。
- フラッシュの全書き換え（`/etc` を作り直す書き込み）をすると inittab が出荷状態に戻り、この行は消える。`S03keepconfig` が引き継ぐのは Wi-Fi・鍵・パスワードで、inittab は含まれない。`/home` は残るので、`-Enable` をもう一度流せばよい。
- 画面が出ない、または暴走したときは、SSH で `-Disable`。SSH が使えなければ USB シリアル（COM23、`tools\ttyshell.py`）でログインして `cp /etc/inittab.before-htop /etc/inittab; kill -HUP 1; killall htop`。

### htop が起動しない（画面に `nommu: Allocation of length … failed`）とき

NOMMU のカーネルは、実行ファイルのコード領域（最初の `LOAD`、R E）を1つの連続した RAM ブロックにコピーして実行する（`/home` の jffs2 は直接実行できない）。ブロックの大きさは、ページ数を2のべき乗に切り上げたもの。RAM は 7.8MB しかなく、動かし続けると断片化して、大きなブロックから先になくなる（起動直後には 512KB のブロックが残っている）。

2026-10-31 に、最初に入れた htop のコード領域が 262,436 バイトで、256KB（262,144）を292バイトだけ超えていた。そのため 512KB のブロックが要り、起動から約15分たったボードでは htop を再起動できなかった（`nommu: Allocation of length 266240 … failed` と `Segmentation fault`。空きは約4MBあったが、最大のブロックは 256KB だった）。起動直後の起動は成功していた。

- 対策: リンクに `--hash-style=sysv` を足して `.gnu.hash`（3.6KB）を外し、コード領域を 258,828 バイト（256KB 未満）にした。ビルドスクリプトは 256KB を超えるとエラーにする。
- 確認: 同じ断片化した状態で、htop を `kill` して `init` に起こさせる試験を4回続けて、毎回成功した（新しい失敗なし）。
- ランチャは、htop が 5 秒もたたずに終わったとき（起動に失敗したとき）は10秒待ってやり直す（3秒ではなく）。カーネルのメモリレポートでコンソールがあふれるのを防ぐため。この分岐も試験で働いた（再起動に約13秒）。
- 空きブロックは `cat /proc/buddyinfo`（左から7番目の列が 256KB、8番目が 512KB のブロック数）。失敗の記録は `dmesg | grep 'nommu: Allocation'`。
- それでも起動しないときは、ボードを再起動する（起動直後の RAM はきれい）。

### 再起動後に SSH がつながらないとき（2026-10-31 に起きたこと）

再起動したボードが Wi-Fi には接続する（`wpa_supplicant` が `CONNECTED`、`iw dev espsta0 link` も接続済み、信号 −68 dBm）のに、DHCP で IP が付かないことがあった。`udhcpc` が Discover を送り続けるだけで、Offer が来ない。再起動のたびに起きた（複数回）。

- 分かったこと: 静的 IP を入れると、ルータへの ping も、PC からの ping も、SSH も通る。Wi-Fi の経路そのものは正常。Discover を送らせたあいだ、実機では UDP 68 番のソケットにも、リンク層の採取（`socat -x INTERFACE:espsta0`、受信フレームだけが見える）にも、DHCP の応答は現れなかった（300 バイト以上のフレームは、別の機器の mDNS だけ）。
- 分からないこと: **原因は未特定**。ルータ側が応答していない可能性が高いと見ているが、確認できていない。実機の採取は送信フレームが見えず、Discover が電波に乗っているかは確かめられない。PC 側は管理者権限が無く、パケットを採取できない。PC の UDP 67 番で待ち受ける試験は、対照に使った普通の UDP ブロードキャストすら届かず（ファイアウォールが疑わしい）、結果が出なかった。
- 画面の htop は IP が無くても出る（自動起動はネットワークに依存しない）。
- 確認先: ルータの DHCP（払い出し一覧、MAC `FC:01:2C:D9:84:30` の固定割り当て、アドレスプールの空き）、ルータの再起動。
- つながらないときの回復: USB シリアル（COM23）から静的 IP を入れる。再起動で消える（フラッシュには何も書かない）。

```powershell
py C:\Users\mizuk\esp32s3-linux\tools\ttyshell.py COM23 C:\Users\mizuk\esp32s3-linux\secrets\board-root-password.txt --timeout 40 --cmdfile C:\Users\mizuk\esp32s3-linux\tools\serial_static_ip.cmds
```

## 注意

- 画面は再起動すると一度消えるが、自動起動を入れてあるので、起動の約12〜13秒後（カーネル起動から）にまた出る（上の節）。
- `/home` はフラッシュなので、htop も設定も再起動後に残る。`/tmp` に送った `htop_start.sh` と `htoprc` は消える（`htop_show.ps1` が毎回送る）。
- htop 自身の `Tasks` には、自分と、SSH のセッション（dropbear）も数えられる。
