#!/usr/bin/env bash
# Export the overlay patch series from a disposable worktree, leaving the
# normal linux-fork worktree and its generated files untouched.
set -euo pipefail

W=$HOME/esp32s3
main=$W/src/linux-fork
repo_root=/mnt/c/Users/mizuk/esp32s3-linux
base=$(git -C "$main" rev-list --max-parents=0 HEAD | tail -n 1)

mkdir -p "$W/checks"
tmp=$(mktemp -d "$W/checks/patch-export.XXXXXX")
wt=$tmp/tree
verify=$tmp/verify
out=$tmp/patches
mkdir -p "$out"

cleanup() {
	env -u GIT_DIR git -C "$main" worktree remove --force "$verify" >/dev/null 2>&1 || true
	env -u GIT_DIR git -C "$main" worktree remove --force "$wt" >/dev/null 2>&1 || true
	rm -rf -- "$tmp"
}
trap cleanup EXIT

git -C "$main" worktree add -q --detach "$wt" "$base"
TREE="$wt" bash "$repo_root/build-scripts/wsl-apply-overlay.sh" >/dev/null
TREE="$wt" PATCH_OUT="$out" bash "$repo_root/build-scripts/wsl-export-patches.sh" >/dev/null

patch=$(find "$out" -maxdepth 1 -type f -name '0004-*.patch' -print -quit)
test -n "$patch" || { echo "T-Deck Plus patch was not generated" >&2; exit 1; }
cp "$patch" "$repo_root/kernel-work/patches/"

git -C "$main" worktree add -q --detach "$verify" "$base"
git -C "$verify" am -q "$repo_root"/kernel-work/patches/0*.patch
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
for f in $files; do
	cmp -s "$verify/$f" "$wt/$f" || {
		echo "patch series differs from overlay: $f" >&2
		exit 1
	}
done

echo "Exported and verified $(basename "$patch") without modifying the main kernel worktree."
