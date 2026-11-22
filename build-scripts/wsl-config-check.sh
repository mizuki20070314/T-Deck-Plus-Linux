#!/bin/bash
# Scratch check of the config: baseline vs AMOLED seed, host compiler, out-of-tree. Touches nothing in the main tree.
set -euo pipefail
W=$HOME/esp32s3
main=$W/src/linux-fork
wt=$W/src/linux-wt
repo=$W/repo/Linux-on-esp32-S3
rm -rf "$wt"; git -C "$main" worktree prune
git -C "$main" worktree add -q --detach "$wt" HEAD
TREE=$wt bash /mnt/c/Users/mizuk/esp32s3-linux/build-scripts/wsl-apply-overlay.sh >/dev/null
cd "$wt"
for name in base amoled; do
  if [ $name = base ]; then seed=$repo/new-files/board/espressif/esp32s3/devkit_c1_16m_linux.config
  else seed=/mnt/c/Users/mizuk/esp32s3-linux/kernel-work/config/waveshare-amoled-143.config; fi
  rm -rf /tmp/kout-$name; mkdir -p /tmp/kout-$name
  cp "$seed" /tmp/kout-$name/.config
  make -s O=/tmp/kout-$name ARCH=xtensa olddefconfig >/tmp/kout-$name/olddefconfig.log 2>&1 || { tail -20 /tmp/kout-$name/olddefconfig.log; exit 1; }
done
echo "=== options that differ between baseline and AMOLED config ==="
diff <(grep -E '^(CONFIG_|# CONFIG_)' /tmp/kout-base/.config | sort) <(grep -E '^(CONFIG_|# CONFIG_)' /tmp/kout-amoled/.config | sort) | grep -E '^[<>]' | grep -v -E 'CONFIG_(CC_|GCC|CLANG|LD_|AS_|TOOLS|PAHOLE|RUSTC|BINDGEN|HAVE_.*COMPILER|CC_HAS)' | head -90