#!/usr/bin/env bash
set -euo pipefail
W=$HOME/esp32s3/ptyrun
B=$HOME/esp32s3/build
host=xtensa-esp32s3-linux-uclibcfdpic
prefix=$B/crosstool-NG/builds/$host/bin/$host
export XTENSA_GNU_CONFIG=$B/xtensa-dynconfig/esp32s3.so
mkdir -p "$W/out"
"$prefix-gcc" -std=c99 -Os -mfdpic -mauto-litpools -fPIC \
    -Wall -Wextra \
    -o "$W/out/ptyrun" /mnt/c/Users/mizuk/esp32s3-linux/tools/ptyrun.c
"$prefix-strip" "$W/out/ptyrun"
"$prefix-size" "$W/out/ptyrun"
"$prefix-readelf" -d "$W/out/ptyrun" | grep NEEDED
sha256sum "$W/out/ptyrun"
