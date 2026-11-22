#!/usr/bin/env bash
# Second half of the fetch: download the htop release tarball, check it against the
# digest GitHub publishes for the asset, unpack both sources into new directories,
# and show what a cross build needs to know (fork users, configure options).
set -euo pipefail

W=$HOME/esp32s3/htop
cd "$W/dl"

read -r name url digest < <(grep -E '^htop-[0-9.]+\.tar\.xz ' assets.txt)
want=${digest#sha256:}
[[ -f $name ]] || curl -fsSL -o "$name" "$url"
echo "$want  $name" | sha256sum -c -

ver=${name#htop-}; ver=${ver%.tar.xz}
mkdir -p "$W/src"
[[ -d $W/src/htop-$ver ]] || tar -xJf "$name" -C "$W/src"
[[ -d $W/src/ncurses-6.4 ]] || tar -xzf ncurses-6.4.tar.gz -C "$W/src"
ls "$W/src"

cd "$W/src/htop-$ver"
echo "=== who calls fork/popen/system/vfork ==="
grep -rnE '\b(fork|vfork|popen|system)\s*\(' --include='*.c' . | grep -v '^./pcp' | head -20
echo "=== configure options ==="
./configure --help | grep -E '^\s+--(enable|disable|with|without)-' | head -60
