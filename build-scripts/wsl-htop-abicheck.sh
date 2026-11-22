#!/usr/bin/env bash
set -u
W=$HOME/esp32s3/htop
B=$HOME/esp32s3/build
p=$B/crosstool-NG/builds/xtensa-esp32s3-linux-uclibcfdpic/bin/xtensa-esp32s3-linux-uclibcfdpic
export XTENSA_GNU_CONFIG=$B/xtensa-dynconfig/esp32s3.so
bl=/mnt/c/Users/mizuk/esp32s3-linux/htop/board-libs
"$p"-nm -D "$W/staging/usr/lib/libncurses.so.6.4" | awk '{print $NF" "$(NF-1)}' | sort > /tmp/mine.syms
"$p"-nm -D "$bl/libncurses.so.6.4"                | awk '{print $NF" "$(NF-1)}' | sort > /tmp/board.syms
echo "mine: $(wc -l < /tmp/mine.syms) symbols, board: $(wc -l < /tmp/board.syms) symbols"
echo "--- only in mine ---";  comm -23 /tmp/mine.syms /tmp/board.syms | head -20
echo "--- only on the board ---"; comm -13 /tmp/mine.syms /tmp/board.syms | head -20