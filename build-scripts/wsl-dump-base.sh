#!/usr/bin/env bash
# Dump the baseline (pre-change) copy of a kernel-tree file and a unified diff against the overlay.
# usage: wsl-dump-base.sh <path-in-tree> <out-dir>
set -euo pipefail
tree=$HOME/esp32s3/src/linux-fork
f=$1
out=$2
base=$(git -C "$tree" rev-list --max-parents=0 HEAD | tail -n 1)
mkdir -p "$out"
git -C "$tree" show "$base:$f" > "$out/$(basename "$f").base"
echo "baseline commit: $base"
