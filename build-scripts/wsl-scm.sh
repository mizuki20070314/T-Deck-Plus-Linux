#!/bin/bash
cd ~/esp32s3/src/linux-fork
echo "=== .scmversion ==="; ls -l .scmversion; echo "content: [$(cat .scmversion)]"
echo "=== scripts/setlocalversion (the parts that matter) ==="
grep -n -B2 -A12 "scmversion\|short=\|LOCALVERSION_AUTO\|git rev-parse" scripts/setlocalversion | head -80
echo "=== what it prints now ==="
sh scripts/setlocalversion . ; echo "[end]"
echo "=== kernel.release / utsrelease ==="
cat include/config/kernel.release 2>/dev/null; grep UTS_RELEASE include/generated/utsrelease.h
echo "=== CONFIG_LOCALVERSION* in .config ==="
grep -E "LOCALVERSION" .config