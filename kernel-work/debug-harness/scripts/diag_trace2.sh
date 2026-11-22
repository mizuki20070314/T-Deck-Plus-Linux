#!/bin/sh
d=/sys/bus/spi/devices/spi0.0
p=/sys/module/spi_esp32/parameters/cs_hold
echo "=== driver flow, cs_hold=Y (shipped): trace of one NOP write ==="
cat $d/cstrace
echo
echo N > $p
echo "=== driver flow, cs_hold=N: trace of one NOP write (run twice) ==="
cat $d/cstrace
cat $d/cstrace
echo Y > $p
echo
echo "=== hand-programmed 1 MHz writes, idle CS level and CS during the transfer ==="
cat $d/engine_probe