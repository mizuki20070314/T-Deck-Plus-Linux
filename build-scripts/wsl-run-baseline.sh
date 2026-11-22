#!/bin/bash
# baseline: the shipped seed, nothing of mine applied
export JOBS=12
exec bash /mnt/c/Users/mizuk/esp32s3-linux/build-scripts/wsl-build-kernel.sh baseline "$HOME/esp32s3/repo/Linux-on-esp32-S3/new-files/board/espressif/esp32s3/devkit_c1_16m_linux.config"