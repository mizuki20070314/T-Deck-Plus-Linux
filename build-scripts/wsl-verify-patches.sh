#!/usr/bin/env bash
# Check that the exported patches apply to the untouched baseline (forkbank, commit
# 62114e2) and give exactly the files of the working tree.
# Run as "builder", after wsl-export-patches.sh.
set -euo pipefail

W=$HOME/esp32s3
tree=${TREE:-$W/src/linux-fork}
patches=/mnt/c/Users/mizuk/esp32s3-linux/kernel-work/patches
mkdir -p "$W/checks"
chk=$(mktemp -d "$W/checks/verify-patches.XXXXXX")
rmdir "$chk"
files="drivers/spi/spi-esp32.c
arch/xtensa/boot/dts/esp32s3-waveshare-amoled-143.dts
drivers/video/fbdev/amoled-qspi-fb.c
drivers/video/fbdev/Kconfig
drivers/video/fbdev/Makefile
arch/xtensa/boot/dts/esp32s3-t-deck-plus.dts
drivers/input/keyboard/tdeck-keyboard.c
drivers/input/keyboard/Kconfig
drivers/input/keyboard/Makefile
Documentation/devicetree/bindings/input/keyboard/lilygo,t-deck-keyboard.yaml"

cd "$tree"
base=$(git rev-list --max-parents=0 HEAD | tail -n 1)
git worktree add -q --detach "$chk" "$base"
trap 'env -u GIT_DIR git -C "$tree" worktree remove --force "$chk" >/dev/null 2>&1 || true' EXIT

cd "$chk"
git config user.email builder@esp32-repro
git config user.name builder
git am -q "$patches"/0*.patch
echo "applied $(git rev-list --count "$base"..HEAD) patches on $base"

rc=0
for f in $files; do
    if cmp -s "$chk/$f" "$tree/$f"; then
        echo "same     $f"
    else
        echo "DIFFERS  $f"
        rc=1
    fi
done
exit $rc
