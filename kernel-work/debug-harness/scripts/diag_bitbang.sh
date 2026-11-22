#!/bin/sh
d=/sys/bus/spi/devices/spi0.0
echo "=== pad test (nothing is sent to the panel) ==="
cat $d/padtest
echo
echo "=== bit-bang init (the panel's frame memory is NOT cleared: noise would be normal) ==="
echo 1 > $d/bbinit
echo "bbinit exit status: $?"
sleep 4
for i in 1 2 3; do
  echo "cycle $i: ALL PIXELS ON now (6 s)"
  echo 23 > $d/bbcmd
  sleep 6
  echo "cycle $i: normal display (3 s)"
  echo 13 > $d/bbcmd
  sleep 3
done
echo "done"