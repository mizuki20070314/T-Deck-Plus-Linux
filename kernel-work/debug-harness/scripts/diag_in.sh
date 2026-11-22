#!/bin/sh
d=/sys/bus/spi/devices/spi0.0
echo "--- BEFORE connecting the input signals ---"
cat $d/cstrace | head -4
echo
echo "--- connect the SPI2 input signals to the same pads (as ESP-IDF does) ---"
echo 1 > $d/in_connect
cat $d/cstrace
echo
echo "--- pads at rest ---"
cat $d/regdump | head -3
echo 0 > $d/in_connect