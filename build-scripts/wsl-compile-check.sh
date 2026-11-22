#!/bin/bash
# Compile-check the new/changed drivers natively (arm64 host gcc, COMPILE_TEST). Touches only the scratch worktree.
set -uo pipefail
W=$HOME/esp32s3
wt=$W/src/linux-wt
O=/tmp/kout-a64
TREE=$wt bash /mnt/c/Users/mizuk/esp32s3-linux/build-scripts/wsl-apply-overlay.sh >/dev/null
cd "$wt"
grep -n -A6 "config SPI_ESP32" drivers/spi/Kconfig | head -10
rm -rf $O; mkdir -p $O
make -s O=$O ARCH=arm64 defconfig >/dev/null
scripts/config --file $O/.config -e COMPILE_TEST -e FB -e SPI -e GPIOLIB -e OF -e FB_AMOLED_QSPI -e SPI_ESP32
make -s O=$O ARCH=arm64 olddefconfig >/dev/null
grep -E '^CONFIG_(FB_AMOLED_QSPI|SPI_ESP32|FB|SPI)=' $O/.config
echo "=== prepare ==="
make -s O=$O ARCH=arm64 -j6 prepare >/tmp/a64-prepare.log 2>&1 || { tail -15 /tmp/a64-prepare.log; exit 1; }
echo "=== compile (W=1) ==="
make O=$O ARCH=arm64 W=1 drivers/video/fbdev/amoled-qspi-fb.o drivers/spi/spi-esp32.o 2>&1 | grep -v -E '^(  (CALL|HOSTCC|UPD|CC|GEN)|make\[)' | head -60
ls -l $O/drivers/video/fbdev/amoled-qspi-fb.o $O/drivers/spi/spi-esp32.o 2>&1