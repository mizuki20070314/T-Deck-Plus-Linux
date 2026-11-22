#!/bin/sh
# time a full-screen update of the AMOLED: echo 1 > refresh, wait until 434312 more bytes went out
d=/sys/bus/spi/devices/spi0.0
FULL=434312
n=0
sum=0
while [ $n -lt 10 ]; do
    b=$(cat $d/statistics/bytes_tx)
    t0=$(cut -d' ' -f1 /proc/uptime | tr -d .)
    echo 1 > $d/refresh
    while [ $(cat $d/statistics/bytes_tx) -lt $((b + FULL)) ]; do sleep 0.01; done
    t1=$(cut -d' ' -f1 /proc/uptime | tr -d .)
    dt=$(( (t1 - t0) * 10 ))
    echo "full update $((n + 1)): ${dt} ms"
    sum=$((sum + dt))
    n=$((n + 1))
    sleep 1
done
echo "average: $((sum / n)) ms for $FULL bytes"
echo "errors: $(cat $d/statistics/errors)  timedout: $(cat $d/statistics/timedout)"