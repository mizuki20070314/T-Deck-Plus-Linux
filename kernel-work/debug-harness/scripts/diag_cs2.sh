#!/bin/sh
d=/sys/bus/spi/devices/spi0.0
echo "--- CS/CLK/D0 pad levels around one NOP register write by the SPI engine (CS should be 1, 0 while selected is not visible, then 1) ---"
cat $d/cstest
echo
echo "--- pad levels at rest, as the SPI engine drives them ---"
cat $d/regdump | head -8