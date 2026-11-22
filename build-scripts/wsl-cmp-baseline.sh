#!/bin/bash
A=~/esp32s3/out/xipImage-baseline
B=/mnt/c/Users/mizuk/esp32s3-linux/kernel-work/out/xipImage-shipped-0.9.1
echo "sizes: $(stat -c %s $A) vs $(stat -c %s $B)"
n=$(cmp -l "$A" "$B" | wc -l)
echo "differing bytes: $n"
echo "=== first differences (offset in hex: mine shipped, octal bytes) ==="
cmp -l "$A" "$B" | head -40 | awk '{printf "0x%06x  %s %s\n", $1-1, $2, $3}'
echo "=== difference span ==="
cmp -l "$A" "$B" | awk 'NR==1{first=$1} {last=$1} END{printf "first 0x%x  last 0x%x  span %d bytes\n", first-1, last-1, last-first+1}'
echo "=== System.map around the kernel start ==="
grep -E " (_text|_stext|_etext|_sdata|_edata|__start_rodata|__end_rodata|_end)$" ~/esp32s3/out/System.map-baseline