#!/usr/bin/env bash
# Download the sources for the htop build: ncurses 6.4 (the version on the board)
# and the latest htop release. Each archive is unpacked into its own new directory.
# Everything downloaded is untrusted data: sha256 is checked, nothing is run from it here.
set -euo pipefail

W=$HOME/esp32s3/htop
mkdir -p "$W/dl" "$W/src"
cd "$W/dl"

# --- ncurses 6.4 (sha256 as in the Buildroot package hash file) ---
nc=ncurses-6.4.tar.gz
nc_sha=6931283d9ac87c5073f30b6290c4c75f21632bb4fc3603ac8100812bed248159
if [[ ! -f $nc ]]; then
    curl -fsSL -o "$nc" "https://ftp.gnu.org/gnu/ncurses/$nc"
fi
echo "$nc_sha  $nc" | sha256sum -c -

# --- htop: latest release asset (tarball with a generated configure script) ---
curl -fsSL -H 'Accept: application/vnd.github+json' \
    https://api.github.com/repos/htop-dev/htop/releases/latest -o release.json
tag=$(python3 -I -c 'import json;print(json.load(open("release.json"))["tag_name"])')
echo "htop latest release: $tag"
python3 -I - <<'PY' > assets.txt
import json
for a in json.load(open("release.json"))["assets"]:
    print(a["name"], a["browser_download_url"], a.get("digest") or "-")
PY
echo "--- release assets (name url digest) ---"
cat assets.txt
