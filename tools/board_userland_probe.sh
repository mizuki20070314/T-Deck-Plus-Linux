#!/bin/sh
echo "=== uname / cpu ==="; uname -a; grep -E 'processor|model|cpu cores|BogoMIPS' /proc/cpuinfo | head -8
echo "=== mounts / df ==="; mount | head -20; df 2>/dev/null
echo "=== inittab ==="; cat /etc/inittab
echo "=== libs ==="; ls -l /lib /usr/lib 2>/dev/null | head -40
echo "=== terminfo ==="; ls -d /usr/share/terminfo /etc/terminfo /lib/terminfo /usr/lib/terminfo 2>&1 | head; echo "TERM=$TERM"
echo "=== busybox ELF header (first 64 bytes) ==="; od -A d -t x1 -N 64 /bin/busybox
ls -l /bin/busybox
echo "=== applets that matter ==="; /bin/busybox --list 2>/dev/null | tr '\n' ' ' | fold -w 100; echo
echo "=== memory ==="; free; cat /proc/buddyinfo
echo "=== processes ==="; ps | head -30
echo "=== tty1 ==="; ls -l /dev/tty1 /dev/console /dev/fb0; stty -F /dev/tty1 -a 2>&1 | head -3