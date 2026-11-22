#!/bin/sh
d=/sys/bus/spi/devices/spi0.0
echo "=== kernel ==="; uname -a
echo "=== boot messages about the panel / SPI ==="
dmesg | grep -iE 'amoled|esp32_spi|spi0|frame buffer|fbcon' 
echo "=== any WARN / BUG / timeout in dmesg? ==="
dmesg | grep -iE 'warn|bug:|timeout|oops|panic' || echo "(none)"
echo "=== sysfs debug attributes should be gone ==="
ls $d | tr '\n' ' '; echo
echo "=== soak: 400 console lines (each one flushes the panel) + 3 fb refreshes ==="
i=0
while [ $i -lt 400 ]; do echo "soak line $i abcdefghijklmnopqrstuvwxyz0123456789" > /dev/tty1; i=$((i+1)); done
echo 1 > $d/refresh; echo 1 > $d/refresh; echo 1 > $d/refresh
usleep 1000 2>/dev/null
cat $d/flush_stats
echo "=== dmesg after soak ==="
dmesg | grep -iE 'warn|bug:|timeout|oops|panic|panel update failed' || echo "(none)"
echo "=== memory ==="
grep -E 'MemTotal|MemFree|MemAvailable' /proc/meminfo