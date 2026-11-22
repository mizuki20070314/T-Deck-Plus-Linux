#!/bin/bash
A=~/esp32s3/out/xipImage-baseline
B=/mnt/c/Users/mizuk/esp32s3-linux/kernel-work/out/xipImage-shipped-0.9.1
for f in "$A" "$B"; do
  echo "=== $(basename $f) ==="
  strings -a -n 20 "$f" | grep -m1 "Linux version"
  strings -a -n 8 "$f" | grep -m3 -E "regulatory|crosstool|2\.42\.50|GNU ld"
done
echo "=== where is the first rodata difference? (offset -> address) ==="
cmp -l "$A" "$B" | awk '{o=$1-1; if (o >= 0x1be718) {printf "first diff at/after rodata: 0x%x  (addr 0x%x)\n", o, 0x42140000+o; exit}}'
echo "=== symbols around linux_banner ==="
grep -E " (linux_banner|linux_proc_banner|regulatory_db|_binary_|__firmware)" ~/esp32s3/out/System.map-baseline | head