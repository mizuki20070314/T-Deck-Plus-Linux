#!/bin/sh
grep -E 'MemFree|MemAvailable' /proc/meminfo | tr '\n' ' '; echo
cat /proc/buddyinfo