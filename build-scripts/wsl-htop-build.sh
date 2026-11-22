#!/usr/bin/env bash
# Cross-build htop for the ESP32-S3 Linux userland (FDPIC, uClibc-ng 1.0.48).
#   wsl-htop-build.sh ncurses   # headers and link stubs, same configuration as Buildroot's
#   wsl-htop-build.sh htop      # htop itself, dynamic, using the board's libncurses.so.6
# Run as "builder". Sources come from wsl-htop-fetch.sh / wsl-htop-fetch2.sh.
set -euo pipefail

W=$HOME/esp32s3/htop
B=$HOME/esp32s3/build
repo=$HOME/esp32s3/repo/Linux-on-esp32-S3/experiments/mmu-poc
staging=$W/staging
host=xtensa-esp32s3-linux-uclibcfdpic
prefix=$B/crosstool-NG/builds/$host/bin/$host
jobs=${JOBS:-$(nproc)}
mkdir -p "$W/logs" "$W/out" "$staging"

export XTENSA_GNU_CONFIG=$B/xtensa-dynconfig/esp32s3.so
export CC=$prefix-gcc AR=$prefix-ar RANLIB=$prefix-ranlib STRIP=$prefix-strip
# The flags the project builds all its programs with (experiments/mmu-poc/programs/env.sh)
cflags='-Os -mfdpic -mauto-litpools -fPIC -ffunction-sections -fdata-sections'

build_ncurses() {
    local src=$W/src/ncurses-6.4 bld=$W/build-ncurses
    rm -rf "$bld"; mkdir -p "$bld"; cd "$bld"
    # Buildroot's ncurses options (package/ncurses), so the headers and the exported
    # symbols match libncurses.so.6.4 on the board.
    "$src"/configure --build="$(gcc -dumpmachine)" --host=$host --prefix=/usr \
        --without-cxx --without-cxx-binding --without-ada --without-tests \
        --disable-big-core --without-profile --disable-rpath --disable-rpath-hack \
        --enable-echo --enable-const --enable-overwrite --enable-pc-files \
        --disable-stripping --with-pkg-config-libdir=/usr/lib/pkgconfig \
        --without-manpages --without-progs --with-shared --with-normal --disable-widec \
        --with-terminfo-dirs=/etc/terminfo:/lib/terminfo:/usr/share/terminfo:/usr/lib/terminfo \
        --with-default-terminfo-dir=/usr/share/terminfo \
        --with-build-cc=gcc --with-build-cflags= --with-build-cppflags= \
        --with-build-ldflags= --with-build-libs= \
        CFLAGS="$cflags"
    make -j"$jobs"
    make install.libs install.includes DESTDIR="$staging"
    echo "--- staged ncurses ---"
    ls -l "$staging"/usr/lib | head -20
}

# The board's libfork.so.0 has no section headers, which ld cannot read, so build the
# same library from the repo's source (same command as fork/build-test.sh) to link
# against. At run time the board's own copy is used.
build_libfork() {
    mkdir -p "$W/stub"
    $CC -std=c99 -Os -mfdpic -mauto-litpools -fPIC -shared -Wall -Wextra -Werror \
        -Wl,-soname,libfork.so.0 "$repo/fork/fork-compat.c" -o "$W/stub/libfork.so.0"
}

build_htop() {
    local src
    src=$(ls -d "$W"/src/htop-[0-9]* | tail -n 1)
    local bld=$W/build-htop
    build_libfork
    # The console is 41 columns wide: no room for " @ Buildroot ..." after the kernel
    # version in the System meter, so leave the distro name out.
    grep -q 'if (false &&' "$src/generic/uname.c" || \
        sed -i 's/if (distro\[0\] && sizeof(savedString) > written/if (false \&\& distro[0] \&\& sizeof(savedString) > written/' \
            "$src/generic/uname.c"
    grep -q 'if (false &&' "$src/generic/uname.c"
    rm -rf "$bld"; mkdir -p "$bld"; cd "$bld"
    # fork() is not declared in the NOMMU headers; libfork.so.0 (on the board) provides it.
    # htop only calls it from the strace/lsof screens and the systemd/OpenRC meters.
    # -D_GNU_SOURCE must come first: the forced include pulls in <sys/types.h> before
    # htop's config.h can define it, and -std=c99 would then hide struct timespec, dirfd.
    export CPPFLAGS="-D_GNU_SOURCE -I$staging/usr/include -include $repo/fork/real/fork-decl.h"
    export CFLAGS="$cflags"
    # --hash-style=sysv: the default emits .hash and .gnu.hash, and the second one (3.6 KB) is
    # what pushes the text segment over 256 KB (see the check after the link).
    export LDFLAGS="-Wl,--gc-sections,--hash-style=sysv,-z,stack-size=131072 -L$staging/usr/lib -L$W/stub"
    export LIBS='-l:libfork.so.0'
    export HTOP_NCURSES_CONFIG_SCRIPT=$staging/usr/bin/ncurses6-config
    "$src"/configure --build="$(gcc -dumpmachine)" --host=$host --prefix=/usr \
        --disable-unicode --disable-hwloc --disable-sensors --disable-capabilities \
        --disable-delayacct --disable-affinity \
        ac_cv_file__proc_stat=yes ac_cv_file__proc_meminfo=yes
    make -j"$jobs"
    "$STRIP" --strip-unneeded -R .xt.prop -R .xt.lit -o "$W/out/htop" htop
    # On a NOMMU kernel the whole read-execute segment (everything up to .eh_frame) is copied
    # into one contiguous block, rounded up to a power of two of pages. Above 256 KB that is a
    # 512 KB block, which a board that has been running for a while no longer has: htop then
    # does not start ("nommu: Allocation of length 266240 from process N (htop) failed").
    local text
    text=$("$prefix-readelf" -lW "$W/out/htop" | awk '$1 == "LOAD" && $8 == "E" { print $5; exit }')
    echo "text segment: $((text)) bytes (limit 262144)"
    if (( text > 0x40000 )); then
        echo "ERROR: the text segment is larger than 256 KB; htop would need a 512 KB block to start" >&2
        exit 1
    fi
    ls -l "$W/out/htop"
    "$prefix-size" "$W/out/htop"
    "$prefix-readelf" -h -d "$W/out/htop" | grep -E 'OS/ABI|Type|Machine|NEEDED|RPATH|RUNPATH'
}

case "${1:-}" in
    ncurses) build_ncurses 2>&1 | tee "$W/logs/ncurses-build.log" | tail -n 40 ;;
    htop)    build_htop 2>&1 | tee "$W/logs/htop-build.log" | tail -n 60 ;;
    *) echo "usage: $0 ncurses|htop" >&2; exit 2 ;;
esac
