#!/usr/bin/env bash
set -u
B=$HOME/esp32s3/build
tc=$B/crosstool-NG/builds/xtensa-esp32s3-linux-uclibcfdpic
sr=$tc/xtensa-esp32s3-linux-uclibcfdpic/sysroot
bl=/mnt/c/Users/mizuk/esp32s3-linux/htop/board-libs
export XTENSA_GNU_CONFIG=$B/xtensa-dynconfig/esp32s3.so
rd=$tc/bin/xtensa-esp32s3-linux-uclibcfdpic-readelf
echo "=== sysroot libs ==="; ls -l "$sr/lib" "$sr/usr/lib" 2>&1 | head -40
echo "=== libc: toolchain sysroot vs board ==="
sha256sum "$sr"/lib/libuClibc-1.0.48.so "$bl"/libuClibc-1.0.48.so "$sr"/lib/ld-uClibc-1.0.48.so "$bl"/ld-uClibc-1.0.48.so "$sr"/lib/libgcc_s.so.1 "$bl"/libgcc_s.so.1 2>&1
echo "=== fork-decl.h ==="; cat /home/builder/esp32s3/repo/Linux-on-esp32-S3/experiments/mmu-poc/fork/real/fork-decl.h
echo "=== board libncurses: NEEDED / soname / key data symbols ==="
"$rd" -d "$bl/libncurses.so.6.4" | grep -E 'NEEDED|SONAME'
"$rd" --dyn-syms -W "$bl/libncurses.so.6.4" | grep -E ' (LINES|COLS|TABSIZE|ESCDELAY|curscr|stdscr|newscr|cur_term|acs_map|UP|BC|PC|ospeed)$|_sp$' | head -12
"$rd" --dyn-syms -W "$bl/libncurses.so.6.4" | grep -cE ' FUNC '
echo "=== libfork exports ==="; "$rd" --dyn-syms -W "$bl/libfork.so.0" | tail -8