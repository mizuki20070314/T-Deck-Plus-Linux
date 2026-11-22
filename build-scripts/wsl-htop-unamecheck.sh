#!/usr/bin/env bash
# The code around the " @ distro" part of htop's System meter, numbered.
cd "$HOME/esp32s3/htop/src/htop-3.5.3" || exit 1
sed -n '78,115p' generic/uname.c | cat -A | sed 's/\$$//' | awk '{printf "%d: %s\n", NR+77, $0}'
