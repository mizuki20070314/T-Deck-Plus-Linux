# CMake toolchain file for the ESP32-S3 Linux userland: xtensa-esp32s3-linux-uclibcfdpic
# (crosstool-NG, FDPIC, uClibc-ng). Used by wsl-fastfetch-build.sh, which sets
# FF_TOOLCHAIN_PREFIX (.../bin/xtensa-esp32s3-linux-uclibcfdpic) and XTENSA_GNU_CONFIG.
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR xtensa)

set(_tc "$ENV{FF_TOOLCHAIN_PREFIX}")
if(NOT _tc)
    message(FATAL_ERROR "FF_TOOLCHAIN_PREFIX is not set")
endif()
set(CMAKE_C_COMPILER "${_tc}-gcc")
set(CMAKE_AR "${_tc}-ar" CACHE FILEPATH "archiver")
set(CMAKE_RANLIB "${_tc}-ranlib" CACHE FILEPATH "ranlib")
set(CMAKE_STRIP "${_tc}-strip" CACHE FILEPATH "strip")
set(CMAKE_NM "${_tc}-nm" CACHE FILEPATH "nm")
set(CMAKE_OBJDUMP "${_tc}-objdump" CACHE FILEPATH "objdump")

# Programs come from the host, libraries and headers only from the target sysroot.
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
