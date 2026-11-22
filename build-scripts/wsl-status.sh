#!/bin/bash
echo "--- processes ---"; pgrep -af 'wsl-toolchain|ct-ng|cc1|ld |make' | cut -c1-110 | head -6
echo "--- ct-ng stage (last lines) ---"
tr '\r' '\n' < ~/esp32s3/logs/toolchain.log | grep -a -E '^\[(INFO |EXTRA|ERROR|WARN |ALL  )' | tail -n 6
echo "--- load ---"; uptime