#!/bin/bash
# Scratch check of the AMOLED seed with the host compiler; changes nothing in the main tree.
set -euo pipefail
W=$HOME/esp32s3
wt=$W/src/linux-wt
cd "$wt"
rm -rf /tmp/kout-amoled; mkdir -p /tmp/kout-amoled
cp /mnt/c/Users/mizuk/esp32s3-linux/kernel-work/config/waveshare-amoled-143.config /tmp/kout-amoled/.config
make -s O=/tmp/kout-amoled ARCH=xtensa olddefconfig
echo "=== ENABLED in the AMOLED config but not in the baseline ==="
diff <(grep -E '^CONFIG_' /tmp/kout-base/.config | sort) <(grep -E '^CONFIG_' /tmp/kout-amoled/.config | sort) | grep -E '^[<>]' | grep -v -E 'CONFIG_(CC_|GCC|CLANG|LD_|AS_|TOOLS|PAHOLE|RUSTC|BINDGEN|HAVE_.*COMPILER)'