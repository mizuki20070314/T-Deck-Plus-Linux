#!/usr/bin/env bash
# Cross-build fastfetch for the ESP32-S3 Linux userland (FDPIC, uClibc-ng 1.0.48), trimmed to what
# a 41x20 console and 7.8 MB of RAM can use.
#   wsl-fastfetch-build.sh [trim|configure|build|all]     (default: all)
# Run as "builder", after wsl-fastfetch-fetch.sh. The pristine source stays untouched: a trimmed
# copy is made, patched and built from.
set -euo pipefail

ver=${FF_VERSION:-2.70.0}
W=$HOME/esp32s3/fastfetch
B=$HOME/esp32s3/build
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$HOME/esp32s3/repo/Linux-on-esp32-S3/experiments/mmu-poc
host=xtensa-esp32s3-linux-uclibcfdpic
pristine=$W/src/fastfetch-$ver
src=$W/src-trim
bld=$W/build
out=$W/out
mkdir -p "$W/logs" "$out"
exec > >(tee "$W/logs/build.log") 2>&1      # everything is also kept in the log file

export FF_TOOLCHAIN_PREFIX=$B/crosstool-NG/builds/$host/bin/$host
export XTENSA_GNU_CONFIG=$B/xtensa-dynconfig/esp32s3.so
prefix=$FF_TOOLCHAIN_PREFIX

# Modules that stay in the build (the rest is switched off with MODULE_DISABLE_<NAME>=ON).
keep_modules="title separator os host kernel uptime cpu memory disk localip loadavg processes colors break custom logo"

# --- 1. a trimmed copy of the source ----------------------------------------------------------------
trim() {
    [[ -d $pristine ]] || { echo "run wsl-fastfetch-fetch.sh first" >&2; exit 1; }
    rm -rf "$src"
    cp -a "$pristine" "$src"
    # 531 built-in logos are about half of the binary. Keep the generic Linux one (and its
    # small variant) and "unknown"; CMake builds a macro from every .txt that is there, and the
    # logo tables only use the logos whose macro exists.
    find "$src/src/logo/ascii" -name '*.txt' ! -name unknown.txt ! -name linux.txt ! -name linux_small.txt -delete
    echo "logos left: $(find "$src/src/logo/ascii" -name '*.txt' | wc -l)"
    # gpu_windows.c is the WSL GPU probe; it needs <uchar.h> (mbstate_t, c16rtomb), which uClibc-ng
    # lacks, and the GPU module is not built anyway.
    sed -i '/gpu_windows\.c[[:space:]]*$/d' "$src/CMakeLists.txt"
    # xtensa falls into the generic branch of the /proc/cpuinfo parser, which reads the CPU name
    # but not the clock ("cpu MHz : 240.00" on this board); add that one line. It fails if the
    # text is not exactly where it is expected, so a new fastfetch version cannot slip through.
    python3 - "$src/src/detection/cpu/cpu_linux.c" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
old = '''            (cpu->name.length == 0 && ffParsePropLine(line, "processor :", &cpu->name)) ||
#endif
'''
new = '''            (cpu->name.length == 0 && ffParsePropLine(line, "processor :", &cpu->name)) ||
            (cpuMHz->length == 0 && ffParsePropLine(line, "cpu MHz :", cpuMHz)) || // xtensa (ESP32 port)
#endif
'''
assert text.count(old) == 1, 'cpu_linux.c: the expected generic branch was not found'
open(path, 'w').write(text.replace(old, new))
PY
    if [[ -d $here/fastfetch-patches ]]; then
        for p in "$here"/fastfetch-patches/*.patch; do
            [[ -e $p ]] || continue
            echo "applying $(basename "$p")"
            patch -d "$src" -p1 < "$p"
        done
    fi
    if [[ -d $here/fastfetch-add ]]; then
        cp -a "$here"/fastfetch-add/. "$src"/      # extra files (compat sources), same layout as the tree
    fi
}

# --- 2. configure -------------------------------------------------------------------------------------
configure() {
    [[ -d $src ]] || trim
    local disable=() m
    for m in "$src"/src/modules/*/; do
        m=$(basename "$m")
        [[ -f $src/src/modules/$m/$m.c ]] || continue
        if [[ " $keep_modules " != *" $m "* ]]; then
            disable+=("-DMODULE_DISABLE_${m^^}=ON")
        fi
    done
    echo "modules kept: $keep_modules"
    echo "modules disabled: ${#disable[@]}"
    # -D_GNU_SOURCE must come before the forced include: <sys/types.h> would otherwise fix the
    # feature macros before the source can set them (same as in the htop build).
    local cflags="-D_GNU_SOURCE -include $repo/fork/real/fork-decl.h -mfdpic -mauto-litpools -fPIC -ffunction-sections -fdata-sections -fno-unwind-tables -fno-asynchronous-unwind-tables"
    local ldflags="-Wl,--gc-sections,--hash-style=sysv,-z,stack-size=131072"
    rm -rf "$bld"
    cmake -S "$src" -B "$bld" -G Ninja \
        -DCMAKE_TOOLCHAIN_FILE="$here/fastfetch-toolchain.cmake" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_FLAGS="$cflags" \
        -DCMAKE_C_FLAGS_RELEASE="-Os -DNDEBUG" \
        -DCMAKE_EXE_LINKER_FLAGS="$ldflags" \
        -DBINARY_LINK_TYPE=dlopen \
        -DENABLE_VULKAN=OFF -DENABLE_WAYLAND=OFF -DENABLE_XCB_RANDR=OFF -DENABLE_XRANDR=OFF \
        -DENABLE_DRM=OFF -DENABLE_VADRM=OFF -DENABLE_VAX11=OFF -DENABLE_VDPAU=OFF -DENABLE_GIO=OFF \
        -DENABLE_DCONF=OFF -DENABLE_EET=OFF -DENABLE_DBUS=OFF -DENABLE_SQLITE3=OFF -DENABLE_RPM=OFF \
        -DENABLE_EGL=OFF -DENABLE_GLX=OFF -DENABLE_OPENCL=OFF -DENABLE_FREETYPE=OFF -DENABLE_ELF=OFF \
        -DENABLE_THREADS=OFF -DENABLE_IMAGE_LOGO=OFF -DENABLE_ZLIB=OFF -DENABLE_LUA=OFF \
        -DENABLE_LIBZFS=OFF -DENABLE_WCWIDTH=OFF -DENABLE_WORDEXP=OFF -DENABLE_LTO=OFF \
        -DBUILD_FLASHFETCH=ON -DBUILD_TESTS=OFF -DSET_TWEAK=OFF -DINSTALL_LICENSE=OFF \
        -DDEFAULT_STRUCTURE="Title:Separator:OS:Host:Kernel:Uptime:CPU:Memory:Disk:LocalIp:Break:Colors" \
        "${disable[@]}"
}

# --- 3. build ---------------------------------------------------------------------------------------------
build() {
    [[ -f $bld/build.ninja ]] || configure
    # The target is "flashfetch": CMake's name for the front end with a fixed layout, replaced by
    # fastfetch-add/src/flashfetch.c. It is installed on the board as "fastfetch".
    ninja -C "$bld" -j"$(nproc)" -k "${FF_NINJA_K:-1}" flashfetch
    "$prefix-strip" --strip-unneeded -R .xt.prop -R .xt.lit -o "$out/fastfetch" "$bld/flashfetch"
    ls -l "$bld/flashfetch" "$out/fastfetch"
    "$prefix-size" "$out/fastfetch"
    "$prefix-readelf" -lW "$out/fastfetch" | awk '$1 == "LOAD" { print }'
    "$prefix-readelf" -d "$out/fastfetch" | grep -E 'NEEDED' || true
    # The read-execute segment must stay below 256 KB (same reason as for htop, see HTOP.md):
    # a NOMMU kernel needs that much RAM in one piece, in a power-of-two number of pages.
    local text
    text=$("$prefix-readelf" -lW "$out/fastfetch" | awk '$1 == "LOAD" && $8 == "E" { print $5; exit }')
    echo "text segment: $((text)) bytes (limit 262144)"
    if (( text > 0x40000 )); then
        echo "ERROR: the text segment is larger than 256 KB" >&2
        exit 1
    fi
}

case "${1:-all}" in
    trim)      trim ;;
    configure) trim; configure ;;
    build)     build ;;
    all)       trim; configure; build ;;
    *) echo "usage: $0 [trim|configure|build|all]" >&2; exit 2 ;;
esac
