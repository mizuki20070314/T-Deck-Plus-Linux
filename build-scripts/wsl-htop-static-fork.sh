#!/usr/bin/env bash
# Rebuild htop with fork-compat.c statically linked, so it no longer needs
# libfork.so.0 at run time (the T-Deck rootfs has no /usr/lib copy and the
# FDPIC loader refuses to resolve fork from the stub in /home/lib).
# Run as "builder". Reuses the existing source tree and staging ncurses.
set -euo pipefail

W=$HOME/esp32s3/htop
B=$HOME/esp32s3/build
repo=$HOME/esp32s3/repo/Linux-on-esp32-S3/experiments/mmu-poc
staging=$W/staging
host=xtensa-esp32s3-linux-uclibcfdpic
prefix=$B/crosstool-NG/builds/$host/bin/$host
jobs=${JOBS:-$(nproc)}

export XTENSA_GNU_CONFIG=$B/xtensa-dynconfig/esp32s3.so
export CC=$prefix-gcc AR=$prefix-ar RANLIB=$prefix-ranlib STRIP=$prefix-strip
cflags='-Os -mfdpic -mauto-litpools -fPIC -ffunction-sections -fdata-sections'

src=$(ls -d "$W"/src/htop-[0-9]* | tail -n 1)
bld=$W/build-htop-static

# fork-compat.c as a plain object; it defines fork(), __register_atfork and
# pthread_atfork locally (pthread symbols come from the board's libc).
"$CC" -std=c99 -Os -mfdpic -mauto-litpools -fPIC \
    -ffunction-sections -fdata-sections -Wall -Wextra -Werror \
    -c "$repo/fork/fork-compat.c" -o "$W/forkcompat.o"

export CPPFLAGS="-D_GNU_SOURCE -I$staging/usr/include -include $repo/fork/real/fork-decl.h"
export CFLAGS="$cflags"
export LDFLAGS="-Wl,--gc-sections,--hash-style=sysv,-z,stack-size=131072 -L$staging/usr/lib"
export LIBS="$W/forkcompat.o"
export HTOP_NCURSES_CONFIG_SCRIPT=$staging/usr/bin/ncurses6-config

rm -rf "$bld"; mkdir -p "$bld"; cd "$bld"
"$src"/configure --build="$(gcc -dumpmachine)" --host=$host --prefix=/usr \
    --disable-unicode --disable-hwloc --disable-sensors --disable-capabilities \
    --disable-delayacct --disable-affinity \
    ac_cv_file__proc_stat=yes ac_cv_file__proc_meminfo=yes
make -j"$jobs"
"$STRIP" --strip-unneeded -R .xt.prop -R .xt.lit -o "$W/out/htop" htop

text=$("$prefix-readelf" -lW "$W/out/htop" | awk '$1 == "LOAD" && $8 == "E" { print $5; exit }')
echo "text segment: $((text)) bytes (limit 262144)"
if (( text > 0x40000 )); then
    echo "ERROR: the text segment is larger than 256 KB" >&2
    exit 1
fi
ls -l "$W/out/htop"
"$prefix-readelf" -d "$W/out/htop" | grep -E 'NEEDED'
