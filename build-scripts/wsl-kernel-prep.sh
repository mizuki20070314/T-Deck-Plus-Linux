#!/usr/bin/env bash
# Prepare the pristine "forkbank" kernel source tree the same way the upstream
# build does it (Buildroot patches + experiments/mmu-poc/fork/*.patch, in the
# order build-kernel.sh / real/build-kernel-slice.sh / build-kernel-reclaim.sh
# apply them). Needs no compiler. Run as user "builder".
#   Result: $W/src/linux-fork   (a git repo, commit "baseline: forkbank 0.9.1")
set -euo pipefail

W=$HOME/esp32s3
repo=$W/repo/Linux-on-esp32-S3
dl=$W/dl
src=$W/src
mkdir -p "$dl" "$src"
set -a
source "$repo/build/sources.lock"
set +a

cd "$dl"
[[ -f linux-$LINUX_VERSION.tar.xz ]] || wget -q "https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-$LINUX_VERSION.tar.xz"
echo "$LINUX_TARBALL_SHA256  linux-$LINUX_VERSION.tar.xz" | sha256sum -c

REGDB=wireless-regdb-2024.07.04
[[ -f $REGDB.tar.xz ]] || wget -q "https://www.kernel.org/pub/software/network/wireless-regdb/$REGDB.tar.xz"
echo "9832a14e1be24abff7be30dee3c9a1afb5fdfcf475a0d91aafef039f8d85f5eb  $REGDB.tar.xz" | sha256sum -c
rm -rf regdb && mkdir regdb && tar -C regdb --strip-components=1 -xf "$REGDB.tar.xz"

tree=$src/linux-fork
if [[ -e $tree ]]; then
    echo "refusing to overwrite existing $tree (remove it first)" >&2
    exit 1
fi
mkdir -p "$tree"
tar -C "$tree" --strip-components=1 -xf "$dl/linux-$LINUX_VERSION.tar.xz"
cd "$tree"

# 1. Buildroot's BR2_LINUX_KERNEL_PATCH series (its apply-patches.sh: patch -g0 -p1 -E -t -N)
n=0
for p in $(ls "$repo"/new-files/board/espressif/esp32s3/patches/linux/*.patch | sort); do
    patch -g0 -p1 -E -t -N -s < "$p" || { echo "FAILED: $p" >&2; exit 1; }
    n=$((n + 1))
done
echo "applied $n board patches"

# 2. what Buildroot's LINUX_INSTALL_REGULATORY_DB hook puts in place
mkdir -p firmware
cp -f "$dl/regdb/regulatory.db" "$dl/regdb/regulatory.db.p7s" firmware/

# 3. the fork backend, in the order the build scripts apply it
f=$repo/experiments/mmu-poc/fork
for p in "$f/kernel.patch" "$f/real/scheduler.patch" "$f/reclaim.patch" "$f/quiet-trace.patch" \
         "$f/swap-banks.patch" "$f/switch-latency.patch" "$f/switch-irqs-on.patch" \
         "$f/mmu-swap.patch" "$f/bank-budget.patch"; do
    patch --batch --forward -p1 -s < "$p" || { echo "FAILED: $p" >&2; exit 1; }
    echo "applied $(basename "$p")"
done

# 4. track it, so every later change is a reviewable commit
git init -q
git config user.email builder@esp32-repro
git config user.name builder
git add -A >/dev/null 2>&1
git commit -q -m "baseline: forkbank 0.9.1 (linux-$LINUX_VERSION + 62 board patches + fork patches)"
git log --oneline | head -2
echo "kernel tree ready: $tree"
