#!/usr/bin/env bash
# Where are the cross compiler, its sysroot and the project's userland recipe?
set -u
W=$HOME/esp32s3
echo "=== top of $W ==="; ls "$W"
echo "=== compilers ==="
find "$W" -maxdepth 6 \( -name '*-gcc' -o -name '*-gcc-[0-9]*' \) -type f 2>/dev/null | head
echo "=== how the kernel build picks the compiler ==="
grep -nE 'CROSS_COMPILE|PATH=|x-tools|toolchain' "$W/../esp32s3-linux/build-scripts/wsl-build-kernel.sh" 2>/dev/null | head -20
grep -nE 'CROSS_COMPILE|PATH=|x-tools|toolchain' /mnt/c/Users/mizuk/esp32s3-linux/build-scripts/wsl-build-kernel.sh | head -20
echo "=== repo top level ==="
ls "$W/repo" | head -60
echo "=== repo mentions of userland building ==="
grep -rIlE 'buildroot|fdpic|uclibc' "$W/repo" --include='*.md' --include='*.sh' --include='*.txt' --include='*defconfig' 2>/dev/null | head -20
echo "=== host tools ==="
for t in curl wget make gcc tic infocmp autoconf xz patchelf file readelf; do printf '%-9s' "$t"; command -v "$t" || echo "(missing)"; done
