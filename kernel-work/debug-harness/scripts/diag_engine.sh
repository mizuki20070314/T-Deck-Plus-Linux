#!/bin/sh
d=/sys/bus/spi/devices/spi0.0
echo "SPI2 programmed by hand: one 32-bit write at 1 MHz (about 32 us). [time CS CLK] at every change:"
cat $d/engine_probe