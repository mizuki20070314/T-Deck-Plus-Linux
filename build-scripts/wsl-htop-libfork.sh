#!/usr/bin/env bash
set -u
B=$HOME/esp32s3/build
p=$B/crosstool-NG/builds/xtensa-esp32s3-linux-uclibcfdpic/bin/xtensa-esp32s3-linux-uclibcfdpic
export XTENSA_GNU_CONFIG=$B/xtensa-dynconfig/esp32s3.so
bl=/mnt/c/Users/mizuk/esp32s3-linux/htop/board-libs
echo "=== board libfork.so.0 dynamic symbols ==="
"$p"-nm -D "$bl/libfork.so.0"
echo "=== where is it built in the repo ==="
grep -rnE 'libfork' /home/builder/esp32s3/repo/Linux-on-esp32-S3/experiments/mmu-poc/fork/*.sh | head -8