#!/usr/bin/env bash
# Build the xtensa-esp32s3-linux-uclibcfdpic toolchain exactly the way the
# upstream project does (build/container-build.sh, toolchain()), natively in WSL2.
#   run as user "builder":   bash wsl-toolchain.sh
# Result: $W/build/crosstool-NG/builds/xtensa-esp32s3-linux-uclibcfdpic/bin/*
set -euo pipefail

W=$HOME/esp32s3
repo=$W/repo/Linux-on-esp32-S3
base=$W/build
export JOBS=${JOBS:-12}
mkdir -p "$W/repo" "$W/logs" "$base"

if [[ ! -d "$repo/.git" ]]; then
    git clone --depth 1 --branch 0.9.1 https://github.com/paulneja/Linux-on-esp32-S3 "$repo"
fi
set -a
source "$repo/build/sources.lock"
set +a

clone_locked() {
    local url=$1 revision=$2 target=$3
    if [[ ! -e "$target" ]]; then
        mkdir -p "$target"
        git -C "$target" init -q
        git -C "$target" remote add origin "$url"
    fi
    test "$(git -C "$target" remote get-url origin)" = "$url"
    if ! git -C "$target" rev-parse --verify HEAD >/dev/null 2>&1; then
        git -C "$target" fetch --depth 1 origin "$revision"
        git -C "$target" checkout --detach FETCH_HEAD
    fi
    test "$(git -C "$target" rev-parse HEAD)" = "$revision"
}

echo "START toolchain $(date -u +%FT%TZ)"
clone_locked https://github.com/jcmvbkbc/xtensa-dynconfig "$DYNCONFIG_REV" "$base/xtensa-dynconfig"
clone_locked https://github.com/jcmvbkbc/config-esp32s3 "$ESP32_CONFIG_REV" "$base/esp32s3"
make -C "$base/xtensa-dynconfig" ORIG=1 CONF_DIR="$base" esp32s3.so
export XTENSA_GNU_CONFIG="$base/xtensa-dynconfig/esp32s3.so"
test -f "$XTENSA_GNU_CONFIG"

clone_locked https://github.com/jcmvbkbc/crosstool-NG "$CTNG_REV" "$base/crosstool-NG"
cd "$base/crosstool-NG"
./bootstrap
./configure --enable-local
make -j"$JOBS"
./ct-ng xtensa-esp32s3-linux-uclibcfdpic
python3 "$repo/build/pin-toolchain.py" .config
CT_PREFIX="$PWD/builds" ./ct-ng build
test -x builds/xtensa-esp32s3-linux-uclibcfdpic/bin/xtensa-esp32s3-linux-uclibcfdpic-gcc
echo "PASS toolchain $(date -u +%FT%TZ)"
