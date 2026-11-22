#!/usr/bin/env bash
# Commit the overlay changes in the kernel tree as four topic commits on top of
# the "baseline" commit and export them as patch files (git format-patch).
# Run as "builder", after wsl-apply-overlay.sh.
set -euo pipefail

W=$HOME/esp32s3
tree=${TREE:-$W/src/linux-fork}
out=${PATCH_OUT:-/mnt/c/Users/mizuk/esp32s3-linux/kernel-work/patches}
cd "$tree"
base=$(git rev-list --max-parents=0 HEAD | tail -n 1)   # the baseline commit
git config user.email builder@esp32-repro
git config user.name builder
# Start from the baseline every time, so the topic commits are rebuilt
# from the current files (no stacked "fixup" commits).
git reset -q --soft "$base"
git reset -q

commit_if_changed() {
    local msg=$1; shift
    git add -- "$@"
    if ! git diff --cached --quiet; then
        git commit -q -m "$msg"
        echo "committed: ${msg%%$'\n'*}"
    fi
}

commit_if_changed "spi: esp32: support dual and quad writes, and frame messages with CS

Honour the per-transfer tx_nbits: set SPI_FWRITE_DUAL / SPI_FWRITE_QUAD for the
data phase, drop full duplex for multi-line writes, and idle all four data
lines high for quad devices like the ESP-IDF SPI master does. Multi-line reads
were advertised but never implemented, so stop advertising them.

Chip select never moved: set_cs wrote MISC without an update, and clearing
CS_KEEP_ACTIVE does not release CS by itself, so CS stayed low for good. Apply
the change with an update and disable the CS line on release. CS now idles
inactive, is asserted for a message and released at its end. A device that
frames its commands with CS (the AMOLED panel) ignores everything otherwise." \
    drivers/spi/spi-esp32.c

commit_if_changed "xtensa: dts: add the Waveshare ESP32-S3-Touch-AMOLED-1.43

Same system as esp32s3-devkit-c1, plus the 466x466 AMOLED on SPI2 in Quad-SPI
mode. The panel pins are not the IO MUX pins of SPI2, so all six lines go
through the GPIO matrix (gpio_out_mux), and the pads use IO MUX function 1.
console=tty0 is added to the kernel command line." \
    arch/xtensa/boot/dts/esp32s3-waveshare-amoled-143.dts

commit_if_changed "video: fbdev: add a Quad-SPI AMOLED (SH8601/CO5300) driver

Framebuffer in RAM, dirty-rectangle updates through a delayed work, register
writes on one line and pixels on four (or one, as a fallback). Supports the
CO5300 and SH8601 init sequences of the Waveshare 1.43\" panel, a brightness
attribute, and refresh/reinit/cmd/flush_stats attributes for bring-up." \
     drivers/video/fbdev/amoled-qspi-fb.c drivers/video/fbdev/Kconfig drivers/video/fbdev/Makefile

commit_if_changed "input: add LilyGO T-Deck Plus board support

Add a T-Deck Plus device tree for the ST7789 display, GT911 touchscreen,
trackball, GPS UART and peripheral power/CS pins. Add the I2C keyboard MCU
driver and its binding; the keyboard reports one ASCII character per I2C read." \
    arch/xtensa/boot/dts/esp32s3-t-deck-plus.dts \
    drivers/input/keyboard/tdeck-keyboard.c \
    drivers/input/keyboard/Kconfig drivers/input/keyboard/Makefile \
    Documentation/devicetree/bindings/input/keyboard/lilygo,t-deck-keyboard.yaml

mkdir -p "$out"
rm -f "$out"/0*.patch
git format-patch --zero-commit -o "$out" "$base"..HEAD
ls -l "$out"
