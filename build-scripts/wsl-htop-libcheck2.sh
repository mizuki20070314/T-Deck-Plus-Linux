#!/usr/bin/env bash
set -u
B=$HOME/esp32s3/build
tc=$B/crosstool-NG/builds/xtensa-esp32s3-linux-uclibcfdpic
bl=/mnt/c/Users/mizuk/esp32s3-linux/htop/board-libs
export XTENSA_GNU_CONFIG=$B/xtensa-dynconfig/esp32s3.so
p=$tc/bin/xtensa-esp32s3-linux-uclibcfdpic
echo "=== sections of the board's libncurses ==="; "$p"-readelf -S -W "$bl/libncurses.so.6.4" 2>&1 | head -30
echo "=== dyn-syms (cross readelf) ==="; "$p"-readelf --dyn-syms -W "$bl/libncurses.so.6.4" 2>&1 | head -12
echo "=== nm -D ==="; "$p"-nm -D "$bl/libncurses.so.6.4" 2>&1 | head -8
echo "=== nm -D count / selected ==="; "$p"-nm -D "$bl/libncurses.so.6.4" 2>&1 | wc -l
"$p"-nm -D "$bl/libncurses.so.6.4" 2>&1 | grep -E ' [BDG] ' | head -20
echo "=== host readelf on libfork ==="; readelf -d -W "$bl/libfork.so.0" 2>&1 | head -12
"$p"-nm -D "$bl/libfork.so.0" 2>&1 | head