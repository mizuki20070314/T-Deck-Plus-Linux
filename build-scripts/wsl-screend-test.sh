#!/usr/bin/env bash
# Test screend on the PC (WSL), natively, with the address and undefined-behaviour sanitizers:
#   1. sha256.h against known values and against Python's hashlib (PBKDF2)
#   2. screend itself, through its HTTP side and its Unix socket (tools/screend/test_screend.py)
# Run as "builder" (or any WSL user with gcc and python3):  bash wsl-screend-test.sh
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
src=$(cd "$here/../tools/screend" && pwd)
page=$src/index.html
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

echo "== crypto =="
gcc -std=gnu11 -O2 -Wall -Wextra -o "$out/test_crypto" "$src/test_crypto.c"
"$out/test_crypto"
python3 - "$out/test_crypto" <<'PY'
import hashlib, subprocess, sys
exe = sys.argv[1]
want = {'abc': hashlib.sha256(b'abc').hexdigest(), '': hashlib.sha256(b'').hexdigest(),
        '1e6': hashlib.sha256(b'a' * 1000000).hexdigest()}
got = subprocess.run([exe], capture_output=True, text=True).stdout.split('\n')
ok = got[0].startswith(want['abc']) and got[1].startswith(want['']) and got[2].startswith(want['1e6'])
print('sha256 vectors match hashlib:', ok)
bad = 0
for pw, salt, it in [('password', 'a1b2c3d4e5f60718', 1), ('password', '73616c74', 2), ('k3Yg7tH2pQ9vXw4zNb6m', 'a1b2c3d4e5f60718', 10000),
                     ('x' * 64, '00112233445566778899aabbccddeeff', 1000), ('p', '0102030405060708', 4096)]:
    r = subprocess.run([exe, pw, salt, str(it), 'x'], capture_output=True, text=True).stdout.strip()
    h = hashlib.pbkdf2_hmac('sha256', pw.encode(), bytes.fromhex(salt), it).hex()
    print('pbkdf2(%r, %s, %d): %s' % (pw[:12], salt[:8], it, 'ok' if r == h else 'MISMATCH ' + r + ' vs ' + h))
    bad += r != h
sys.exit(0 if ok and not bad else 1)
PY

echo "== screend (native, sanitizers) =="
gcc -std=gnu11 -O1 -g -fsanitize=address,undefined -fno-omit-frame-pointer -Wall -Wextra -o "$out/screend_host" "$src/screend.c"
python3 "$src/test_screend.py" "$out/screend_host" "$page"
