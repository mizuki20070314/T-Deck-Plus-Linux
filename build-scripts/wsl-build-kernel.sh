#!/usr/bin/env bash
# Configure and build xipImage the way build-kernel.sh / build-kernel-reclaim.sh
# of the upstream project do, with the same reproducible-build variables.
#   usage: wsl-build-kernel.sh NAME SEED_CONFIG
#   e.g.   wsl-build-kernel.sh baseline /home/builder/esp32s3/repo/Linux-on-esp32-S3/new-files/board/espressif/esp32s3/devkit_c1_16m_linux.config
# Output: $W/out/xipImage-NAME (+ config-NAME, System.map-NAME), copied to
# C:\Users\mizuk\esp32s3-linux\kernel-work\out\ as well. Run as "builder".
set -euo pipefail

name=${1:?name}
seed=${2:?seed config}
W=$HOME/esp32s3
tree=${TREE:-$W/src/linux-fork}
base=$W/build
repo=$W/repo/Linux-on-esp32-S3
winout=/mnt/c/Users/mizuk/esp32s3-linux/kernel-work/out
tc=$base/crosstool-NG/builds/xtensa-esp32s3-linux-uclibcfdpic/bin/xtensa-esp32s3-linux-uclibcfdpic-
test -x "${tc}gcc" || { echo "toolchain not built yet: ${tc}gcc" >&2; exit 1; }

export XTENSA_GNU_CONFIG=$base/xtensa-dynconfig/esp32s3.so
export KBUILD_BUILD_USER=builder KBUILD_BUILD_HOST=esp32-repro
export KBUILD_BUILD_TIMESTAMP='Sat Sep 5 00:00:00 UTC 2026' KBUILD_BUILD_VERSION=1
export SOURCE_DATE_EPOCH=1788566400
JOBS=${JOBS:-12}
mkdir -p "$W/out" "$W/logs" "$winout"

cd "$tree"
# The tree is a git repo here; scripts/setlocalversion would append
# "-g<commit>" to the release string, which the upstream tarball build does not
# have. Hide the repository from the build instead of changing the config.
export GIT_DIR=/nonexistent
rm -f .scmversion
cp "$seed" .config
make ARCH=xtensa CROSS_COMPILE="$tc" olddefconfig
scripts/config --enable XTENSA_NOMMU_FORK --set-str LOCALVERSION '-forkbank'
make ARCH=xtensa CROSS_COMPILE="$tc" olddefconfig
python3 "$repo/experiments/mmu-poc/fork/check-kernel-config.py" "$seed" .config

make -j"$JOBS" ARCH=xtensa CROSS_COMPILE="$tc" xipImage 2>&1 | tee "$W/logs/kernel-$name.log" | tail -n 25

img=arch/xtensa/boot/xipImage
size=$(stat -c %s "$img")
test "$size" -le $((0x400000)) || { echo "xipImage is $size bytes: over the 4 MiB linux partition" >&2; exit 1; }
cp -f "$img" "$W/out/xipImage-$name"
cp -f .config "$W/out/config-$name"
cp -f System.map "$W/out/System.map-$name"
cp -f "$W/out/xipImage-$name" "$W/out/config-$name" "$W/out/System.map-$name" "$winout/"
echo "RESULT $name: $size bytes"
sha256sum "$W/out/xipImage-$name"
