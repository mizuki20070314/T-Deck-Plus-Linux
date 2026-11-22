#!/bin/sh
echo "=== terminfo contents ==="
for d in /usr/share/terminfo /usr/lib/terminfo; do echo "-- $d"; find $d -type f 2>/dev/null | head -20; done
echo "=== /home ==="; ls -la /home /home/root 2>&1 | head -30
echo "=== env in ssh session ==="; echo "HOME=$HOME USER=$USER SHELL=$SHELL PATH=$PATH"
echo "=== libfork / ld ==="; ls -l /usr/lib/libfork.so.0 /lib/ld-uClibc.so.1
echo "=== swap ==="; cat /proc/swaps; grep -E 'Swap|Cached|Buffers|Slab' /proc/meminfo
echo "=== vm sysctl ==="; cat /proc/sys/vm/overcommit_memory /proc/sys/vm/min_free_kbytes 2>&1