#!/bin/sh
dmesg | grep -iE 'amoled|frame buffer'
echo "fb0 virtual_size: $(cat /sys/class/graphics/fb0/virtual_size)"
stty -F /dev/tty1 -a | head -1
grep -E 'MemFree|MemAvailable' /proc/meminfo | tr '\n' ' '; echo
cat /sys/bus/spi/devices/spi0.0/flush_stats