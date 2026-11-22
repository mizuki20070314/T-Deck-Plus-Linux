#!/bin/bash
# Build the T-Deck Plus profile in a disposable worktree, preserving the main
# kernel worktree and its generated files.
set -euo pipefail

W=$HOME/esp32s3
main=$W/src/linux-fork
repo_root=/mnt/c/Users/mizuk/esp32s3-linux

mkdir -p "$W/checks"
wt=$(mktemp -d "$W/checks/t-deck-plus-build.XXXXXX")
rmdir "$wt"

cleanup() {
	env -u GIT_DIR git -C "$main" worktree remove --force "$wt" >/dev/null 2>&1 || true
}
trap cleanup EXIT

git -C "$main" worktree add -q --detach "$wt" HEAD
TREE="$wt" bash "$repo_root/build-scripts/wsl-apply-overlay.sh"
export JOBS=12
TREE="$wt" bash "$repo_root/build-scripts/wsl-build-kernel.sh" t-deck-plus "$repo_root/kernel-work/config/t-deck-plus.config"
