#!/bin/bash
cd ~/esp32s3/src/linux-fork
echo "git status (should be empty = pristine baseline):"; git status --short | head -5; echo "[end]"
echo "toolchain gcc:"; XTENSA_GNU_CONFIG=~/esp32s3/build/xtensa-dynconfig/esp32s3.so ~/esp32s3/build/crosstool-NG/builds/xtensa-esp32s3-linux-uclibcfdpic/bin/xtensa-esp32s3-linux-uclibcfdpic-gcc --version | head -1