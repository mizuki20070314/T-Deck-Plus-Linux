#!/bin/sh
d=/sys/bus/spi/devices/spi0.0
echo "full-screen refresh x5 (the stats keep the largest update):"
for i in 1 2 3 4 5; do echo 1 > $d/refresh; sleep 1; done
cat $d/flush_stats
echo "errors: $(cat $d/statistics/errors)  timedout: $(cat $d/statistics/timedout)"