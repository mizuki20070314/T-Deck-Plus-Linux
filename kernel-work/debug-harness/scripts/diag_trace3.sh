#!/bin/sh
d=/sys/bus/spi/devices/spi0.0
echo "=== CS framing of one NOP write through the driver (CS should rest high, go low for the write, and come back high) ==="
cat $d/cstrace
echo
echo "=== pads at rest ==="
cat $d/regdump | head -3