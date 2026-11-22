#!/bin/bash
# build the AMOLED kernel: overlay + display seed
set -euo pipefail
bash /mnt/c/Users/mizuk/esp32s3-linux/build-scripts/wsl-apply-overlay.sh
export JOBS=12
exec bash /mnt/c/Users/mizuk/esp32s3-linux/build-scripts/wsl-build-kernel.sh amoled /mnt/c/Users/mizuk/esp32s3-linux/kernel-work/config/waveshare-amoled-143.config