#!/bin/sh
d=/sys/bus/spi/devices/spi0.0
echo "--- trace of one NOP write at 100 kHz ---"
cat $d/cstrace
echo
echo "--- the same again ---"
cat $d/cstrace