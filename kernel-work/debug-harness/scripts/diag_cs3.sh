#!/bin/sh
d=/sys/bus/spi/devices/spi0.0
p=/sys/module/spi_esp32/parameters/cs_hold
echo "--- cs_hold=Y (SPI_CS_HOLD+SPI_CS_SETUP set): pads around a NOP write ---"
cat $d/cstest | tail -4
echo
echo N > $p
echo "--- cs_hold=N (both bits clear): pads around a NOP write ---"
echo "cs_hold = $(cat $p)"
cat $d/cstest
echo
echo "--- at rest afterwards ---"
cat $d/regdump | head -3
echo Y > $p