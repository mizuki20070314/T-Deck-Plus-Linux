#!/bin/sh
d=/sys/bus/spi/devices/spi0.0
echo "--- before: SPI engine routing as configured ---"
cat $d/regdump | head -3
echo "--- force the pads' output enable on (signals stay the engine's) ---"
echo 1 > $d/oe_force
cat $d/regdump | head -8
echo "--- a NOP write by the engine, CS/CLK/D0 around it ---"
cat $d/cstest
echo "--- give the output enable back ---"
echo 0 > $d/oe_force
cat $d/regdump | head -3