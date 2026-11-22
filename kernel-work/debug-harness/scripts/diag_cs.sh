#!/bin/sh
d=/sys/bus/spi/devices/spi0.0
p=/sys/module/spi_esp32/parameters/cs_hold
ls /sys/module/spi_esp32/parameters/
echo "cs_hold = $(cat $p)   (Y: SPI_CS_HOLD + SPI_CS_SETUP on every transfer, the shipped behaviour)"
echo
echo "--- 1. cs_hold=Y: pad levels around one NOP register write by the SPI engine ---"
cat $d/cstest
echo
echo "--- 2. cs_hold=N ---"
echo N > $p
echo "cs_hold = $(cat $p)"
cat $d/cstest
echo
echo "--- 3. back to Y, again ---"
echo Y > $p
cat $d/cstest