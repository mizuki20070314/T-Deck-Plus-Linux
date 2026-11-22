#!/usr/bin/env bash
# Build the evpeek input-event dumper for the T-Deck Plus (FDPIC uClibc dynamic).
# Run as "builder".
set -euo pipefail

W=$HOME/esp32s3/evpeek
B=$HOME/esp32s3/build
host=xtensa-esp32s3-linux-uclibcfdpic
prefix=$B/crosstool-NG/builds/$host/bin/$host

export XTENSA_GNU_CONFIG=$B/xtensa-dynconfig/esp32s3.so

mkdir -p "$W/out"
"$prefix-gcc" -std=c99 -Os -mfdpic -mauto-litpools -fPIC \
    -Wall -Wextra -Werror \
    -o "$W/out/evpeek" /mnt/c/Users/mizuk/esp32s3-linux/tools/evpeek.c
"$prefix-strip" "$W/out/evpeek"
"$prefix-size" "$W/out/evpeek"
"$prefix-readelf" -d "$W/out/evpeek" | grep NEEDED
sha256sum "$W/out/evpeek"
