#!/usr/bin/env bash
# Copy the overlay (kernel-work/overlay on the Windows side) into the kernel
# tree and hook the new driver into Kconfig/Makefile. Idempotent. Run as "builder".
set -euo pipefail

W=$HOME/esp32s3
tree=${TREE:-$W/src/linux-fork}
ov=/mnt/c/Users/mizuk/esp32s3-linux/kernel-work/overlay

cd "$tree"
# overlay files are plain copies; the Windows side may have written CRLF
( cd "$ov" && find . -type f ) | while read -r f; do
    mkdir -p "$(dirname "$tree/$f")"
    tr -d '\r' < "$ov/$f" > "$tree/$f"
done

if ! grep -q 'config FB_AMOLED_QSPI' drivers/video/fbdev/Kconfig; then
    python3 - <<'PY'
import re
p = "drivers/video/fbdev/Kconfig"
s = open(p).read()
block = '''config FB_AMOLED_QSPI
	tristate "Quad-SPI AMOLED (SH8601/CO5300) framebuffer support"
	depends on FB && SPI && GPIOLIB
	select FB_SYSMEM_HELPERS
	help
	  Framebuffer driver for AMOLED panels with an SH8601 or CO5300
	  controller on a Quad-SPI bus, such as the 466x466 panel of the
	  Waveshare ESP32-S3-Touch-AMOLED-1.43.

	  The framebuffer is kept in RAM and the parts that change are sent
	  to the panel from a delayed work. Say Y here to use it as the
	  framebuffer console.

'''
marker = "config FB_SM712\n"
assert marker in s
open(p, "w").write(s.replace(marker, block + marker, 1))
PY
fi
if ! grep -q 'FB_AMOLED_QSPI' drivers/video/fbdev/Makefile; then
    sed -i '/^obj-\$(CONFIG_FB_SSD1307)/a obj-$(CONFIG_FB_AMOLED_QSPI)	+= amoled-qspi-fb.o' drivers/video/fbdev/Makefile
fi

if ! grep -q 'config KEYBOARD_TDECK' drivers/input/keyboard/Kconfig; then
    python3 - <<'PY'
p = "drivers/input/keyboard/Kconfig"
s = open(p).read()
marker = "config KEYBOARD_TCA8418\n"
block = '''config KEYBOARD_TDECK
	tristate "LilyGO T-Deck I2C keyboard"
	depends on I2C
	help
	  Say Y here to support the keyboard MCU used by the LilyGO T-Deck and
	  T-Deck Plus. The MCU returns one ASCII character per I2C read.

	  To compile this driver as a module, choose M here: the module will be
	  called tdeck-keyboard.

'''
assert marker in s
open(p, "w").write(s.replace(marker, block + marker, 1))
PY
fi

if ! grep -q 'CONFIG_KEYBOARD_TDECK' drivers/input/keyboard/Makefile; then
    printf '%s\n' 'obj-$(CONFIG_KEYBOARD_TDECK)	+= tdeck-keyboard.o' >> drivers/input/keyboard/Makefile
fi

grep -n 'AMOLED' drivers/video/fbdev/Makefile drivers/video/fbdev/Kconfig | head -4
grep -n 'KEYBOARD_TDECK' drivers/input/keyboard/Makefile drivers/input/keyboard/Kconfig

if ! grep -q 'config SND_SOC_ESP32S3_I2S' sound/soc/xtensa/Kconfig; then
	python3 - <<'PY'
p = "sound/soc/xtensa/Kconfig"
s = open(p).read()
marker = "endmenu\n"
block = '''config SND_SOC_ESP32S3_I2S
	tristate "Espressif ESP32-S3 I2S audio"
	depends on XTENSA_PLATFORM_ESP32
	depends on OF
	help
	  ALSA SoC support for the ESP32-S3 I2S0 transmitter and I2S1
	  receiver. Audio samples are transferred by the on-chip GDMA engine.
	  The T-Deck Plus firmware must reserve internal SRAM for DMA descriptors.

'''
assert marker in s
open(p, "w").write(s.replace(marker, block + marker, 1))
PY
fi
if ! grep -q 'CONFIG_SND_SOC_ESP32S3_I2S' sound/soc/xtensa/Makefile; then
	printf '%s\n' 'obj-$(CONFIG_SND_SOC_ESP32S3_I2S) += esp32s3-i2s.o' >> sound/soc/xtensa/Makefile
fi

if ! grep -q 'config SND_SOC_ES7210' sound/soc/codecs/Kconfig; then
	python3 - <<'PY'
p = "sound/soc/codecs/Kconfig"
s = open(p).read()
marker = "config SND_SOC_ES7134\n"
block = '''config SND_SOC_ES7210
	tristate "Everest Semi ES7210 ADC codec"
	depends on I2C
	select REGMAP_I2C
	help
	  Enable support for the Everest Semiconductor ES7210 four-channel
	  audio ADC. The T-Deck Plus uses its SDOUT1 output in four-slot TDM.

'''
assert marker in s
open(p, "w").write(s.replace(marker, block + marker, 1))
PY
fi
if ! grep -q 'CONFIG_SND_SOC_ES7210' sound/soc/codecs/Makefile; then
	python3 - <<'PY'
p = "sound/soc/codecs/Makefile"
s = open(p).read()
marker = "obj-$(CONFIG_SND_SOC_ES7134)"
line = "obj-$(CONFIG_SND_SOC_ES7210)\t+= es7210.o\n"
assert marker in s
open(p, "w").write(s.replace(marker, line + marker, 1))
PY
fi

grep -n 'ESP32S3_I2S' sound/soc/xtensa/Makefile sound/soc/xtensa/Kconfig
grep -n 'SND_SOC_ES7210' sound/soc/codecs/Makefile sound/soc/codecs/Kconfig
git status --short | head -20
