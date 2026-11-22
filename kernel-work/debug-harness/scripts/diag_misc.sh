#!/bin/sh
d=/sys/bus/spi/devices/spi0.0
echo 1 > $d/oe_force
echo "pads driven by the engine's own signals (output enable forced on):"
cat $d/misc_sweep
echo 0 > $d/oe_force