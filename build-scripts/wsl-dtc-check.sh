#!/bin/bash
set -e
cd ~/esp32s3/src/linux-fork
ov=/mnt/c/Users/mizuk/esp32s3-linux/kernel-work/overlay/arch/xtensa/boot/dts/esp32s3-waveshare-amoled-143.dts
tr -d '\r' < "$ov" > /tmp/wsav.dts
cpp -nostdinc -I include -I arch/xtensa/boot/dts -undef -D__DTS__ -x assembler-with-cpp /tmp/wsav.dts > /tmp/wsav.pp.dts
dtc -I dts -O dtb -W no-unit_address_vs_reg -W no-simple_bus_reg -o /tmp/wsav.dtb /tmp/wsav.pp.dts
echo "dtc OK: $(stat -c %s /tmp/wsav.dtb) bytes"
dtc -I dtb -O dts /tmp/wsav.dtb 2>/dev/null > /tmp/wsav.back.dts
echo "=== spi@60024000 ==="
awk '/spi@60024000 \{/,/^\t\t\};/' /tmp/wsav.back.dts
echo "=== pinctrl state nodes ==="
grep -n -B1 -A9 "spi2_pins\|spi2_out" /tmp/wsav.back.dts | head -60
echo "=== chosen ==="
grep -A3 "chosen {" /tmp/wsav.back.dts