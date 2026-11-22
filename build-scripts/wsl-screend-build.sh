#!/usr/bin/env bash
# Cross-build screend for the ESP32-S3 Linux userland (FDPIC, uClibc-ng 1.0.48).
#   wsl-screend-build.sh
# Run as "builder". Output: ~/esp32s3/screend/out/screend (stripped), copied to
# tools/screend/out/ by the caller if wanted.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
src=$(cd "$here/../tools/screend" && pwd)
W=$HOME/esp32s3/screend
B=$HOME/esp32s3/build
host=xtensa-esp32s3-linux-uclibcfdpic
prefix=$B/crosstool-NG/builds/$host/bin/$host
export XTENSA_GNU_CONFIG=$B/xtensa-dynconfig/esp32s3.so
mkdir -p "$W/out"

# The flags the project builds all its programs with (experiments/mmu-poc/programs/env.sh).
# The stack is 32 KB: the deepest path of screend uses about a third of that, and on a NOMMU
# kernel every process needs its stack as one block of RAM (and nothing guards it).
"$prefix-gcc" -std=gnu11 -Os -Wall -Wextra -D_GNU_SOURCE \
    -mfdpic -mauto-litpools -fPIC -ffunction-sections -fdata-sections \
    -fno-unwind-tables -fno-asynchronous-unwind-tables \
    -Wl,--gc-sections,--hash-style=sysv,-z,stack-size=32768 \
    -o "$W/out/screend.unstripped" "$src/screend.c"
"$prefix-strip" --strip-unneeded -R .xt.prop -R .xt.lit -o "$W/out/screend" "$W/out/screend.unstripped"

ls -l "$W/out/screend"
"$prefix-size" "$W/out/screend"
"$prefix-readelf" -lW "$W/out/screend" | awk '$1 == "LOAD" || $1 == "GNU_STACK" { print }'
"$prefix-readelf" -d "$W/out/screend" | grep NEEDED || true

# The read-execute segment is one block of RAM on a NOMMU kernel, rounded up to a power of
# two of pages (HTOP.md): stay at or below 128 KB.
text=$("$prefix-readelf" -lW "$W/out/screend" | awk '$1 == "LOAD" && $8 == "E" { print $5; exit }')
echo "text segment: $((text)) bytes (limit 131072)"
if (( text > 0x20000 )); then
    echo "ERROR: the text segment is larger than 128 KB" >&2
    exit 1
fi
