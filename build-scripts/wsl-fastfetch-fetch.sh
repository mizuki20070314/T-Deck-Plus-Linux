#!/usr/bin/env bash
# Fetch fastfetch's source into its own directory and unpack it.
#   wsl-fastfetch-fetch.sh [VERSION]      (default 2.70.0)
# GitHub publishes no digest for source archives, so the archive is checked against the commit
# that the tag points to: `git archive` (which GitHub uses) records the commit id in a pax
# header at the start of the tar, and the GitHub API says which commit the tag is.
set -euo pipefail

ver=${1:-2.70.0}
W=$HOME/esp32s3/fastfetch
mkdir -p "$W/dl" "$W/src"
cd "$W/dl"

want=$(curl -fsSL "https://api.github.com/repos/fastfetch-cli/fastfetch/commits/$ver" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["sha"])')
[[ -f fastfetch-$ver.tar.gz ]] || \
    curl -fsSL -o "fastfetch-$ver.tar.gz" "https://github.com/fastfetch-cli/fastfetch/archive/refs/tags/$ver.tar.gz"
# (pipefail off here: gzip gets SIGPIPE when head has read enough, which is expected)
got=$(set +o pipefail; gzip -dc "fastfetch-$ver.tar.gz" | head -c 2048 | tr -c '[:print:]\n' '\n' | grep -oE '[0-9a-f]{40}' | head -n 1)
echo "tag commit (GitHub API): $want"
echo "commit in the archive  : $got"
[[ -n $want && $want == "$got" ]] || { echo "MISMATCH: not unpacking" >&2; exit 1; }
sha256sum "fastfetch-$ver.tar.gz"

[[ -d $W/src/fastfetch-$ver ]] || tar -xzf "fastfetch-$ver.tar.gz" -C "$W/src"
ls "$W/src"
