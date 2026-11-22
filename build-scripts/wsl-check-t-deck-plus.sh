#!/usr/bin/env bash
# Validate the T-Deck Plus DTS and affected drivers in a disposable worktree.
set -euo pipefail

W=$HOME/esp32s3
main=$W/src/linux-fork
repo=$W/repo/Linux-on-esp32-S3
seed=/mnt/c/Users/mizuk/esp32s3-linux/kernel-work/config/t-deck-plus.config
tc=$W/build/crosstool-NG/builds/xtensa-esp32s3-linux-uclibcfdpic/bin/xtensa-esp32s3-linux-uclibcfdpic-

test -x "${tc}gcc" || { echo "missing cross compiler: ${tc}gcc" >&2; exit 1; }
mkdir -p "$W/checks"
wt=$(mktemp -d "$W/checks/t-deck-plus.XXXXXX")
rmdir "$wt"
out=$(mktemp -d /tmp/tdeck-plus-obj.XXXXXX)

cleanup() {
    env -u GIT_DIR git -C "$main" worktree remove --force "$wt" >/dev/null 2>&1 || true
    rm -rf -- "$out"
}
trap cleanup EXIT

git -C "$main" worktree add -q --detach "$wt" HEAD
TREE="$wt" bash /mnt/c/Users/mizuk/esp32s3-linux/build-scripts/wsl-apply-overlay.sh >/dev/null

export XTENSA_GNU_CONFIG=$W/build/xtensa-dynconfig/esp32s3.so
export KBUILD_BUILD_USER=builder KBUILD_BUILD_HOST=esp32-repro
export KBUILD_BUILD_TIMESTAMP='Sat Sep 5 00:00:00 UTC 2026' KBUILD_BUILD_VERSION=1
export SOURCE_DATE_EPOCH=1788566400

cp "$seed" "$out/.config"
make -s -C "$wt" O="$out" ARCH=xtensa CROSS_COMPILE="$tc" olddefconfig
"$wt/scripts/config" --file "$out/.config" --enable XTENSA_NOMMU_FORK \
    --set-str LOCALVERSION '-forkbank'
make -s -C "$wt" O="$out" ARCH=xtensa CROSS_COMPILE="$tc" olddefconfig
python3 "$repo/experiments/mmu-poc/fork/check-kernel-config.py" "$seed" "$out/.config"
make -s -C "$wt" O="$out" ARCH=xtensa CROSS_COMPILE="$tc" prepare
make -s -C "$wt" O="$out" ARCH=xtensa CROSS_COMPILE="$tc" W=1 \
    dtbs \
    drivers/input/keyboard/tdeck-keyboard.o \
    drivers/input/keyboard/gpio_keys.o \
    drivers/input/touchscreen/goodix.o \
    drivers/staging/fbtft/fb_st7789v.o \
    sound/soc/xtensa/esp32s3-i2s.o \
    sound/soc/codecs/es7210.o \
    sound/soc/codecs/max98357a.o \
    sound/soc/generic/simple-card.o

echo "T-Deck Plus DTS and driver object checks passed."
