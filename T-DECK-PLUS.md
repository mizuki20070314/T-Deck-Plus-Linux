# T-Deck Plus port

For application development (pin map, devices, kernel features, NOMMU rules,
toolchain), see [`T-DECK-PLUS-SPEC.md`](T-DECK-PLUS-SPEC.md).

This profile adds a T-Deck Plus kernel target alongside the existing Waveshare
AMOLED target. The SoC, 16 MiB flash and 8 MiB PSRAM match the existing Linux
image, so the Linux/userland partition layout stays unchanged.

## Enabled hardware

| Hardware | Linux setup |
|---|---|
| ST7789, 320×240 LCD | SPI2 + upstream FBTFT `fb_st7789v`; FBTFT portrait geometry is rotated 270° to landscape |
| LCD backlight | GPIO42 held high at boot |
| Peripheral power | GPIO10 held high at boot (required on battery power) |
| GT911 touch | GPIO-I2C on SDA18/SCL8, address 0x5d, IRQ GPIO16 |
| Keyboard | I2C address 0x55; the driver polls the firmware raw key-matrix report (command 0x03) every 10 ms and falls back to ASCII character polling; holding Mic reports LEFTCTRL, a standalone SYM press reports Tab |
| Trackball | GPIO keys: center=GPIO0, up=GPIO3, down=GPIO15, left=GPIO1, right=GPIO2 |
| GPS | UART0 remains available as `/dev/ttyS0` at 9600 baud on TX43/RX44 |
| Speaker | ALSA playback, I2S0 / MAX98357A, `/dev/snd/...` (`T-Deck Plus Speaker`) |
| Microphone | ALSA capture, I2S1 / ES7210 TDM, 16 kHz stereo from MIC1/MIC3 (`T-Deck Plus Microphone`) |
| USB console | ESP32-S3 USB Serial/JTAG `ttyGS3`; UART0 is deliberately not a console because it is wired to GPS |

The T-Deck Plus DTS uses GPIO9 and GPIO39 as inactive-high LoRa and SD-card
chip selects, respectively. LoRa and TF-card storage are still not enabled in
this port. Audio is enabled as two ALSA sound cards: an I2S0/MAX98357A playback
device and an I2S1/ES7210 TDM capture device (MIC1 and MIC3 as stereo). The
MAX98357A amplifier is powered through the GPIO10 peripheral rail, so no
separate SD-mode control is required. Audio uses GDMA channels 0 (TX) and 1
(RX), with descriptor memory taken from a page reserved immediately after the
Linux exception vectors in Core 0 firmware.

The audio path requires a matching firmware update. The patch
`patches/03-audio-dma-reservation.patch` expands Core 0's
`space_for_vectors` reservation to 8 KiB: its first page holds Linux vectors,
and its second page holds GDMA descriptors. The firmware writes the descriptor
pool magic before entering Linux. The kernel maps that page through the
ESP32-S3 D/IRAM data-bus alias (`0x40381000` IRAM → `0x3fc91000` DRAM for the
current vector address). To apply it:

1. Run `apply-local-changes.sh esp-hosted` in the upstream build tree (this
   applies the firmware integration, IDF compatibility, and DMA reservation
   patches).
2. Rebuild `network_adapter` with the ESP-IDF toolchain.
3. Package the image with `make-images.sh`.

`make-images.sh` automatically verifies that the firmware's
`space_for_vectors` address matches `CONFIG_VECTORS_ADDR` in the kernel config.
The kernel's `CONFIG_VECTORS_ADDR` must continue to match the firmware's
`space_for_vectors` symbol. The firmware and kernel must both be rebuilt after
changing the reservation or its address.

The I2S reset is pulsed with reset-controller assert/deassert because the
ESP32 `reset-simple` provider's `reset()` operation returns `-ENOTSUPP` when no
`reset-us` delay is configured. GDMA IRQs use external CPU IRQs 13 and 17 (IRQ14
is the Xtensa NMI; IRQ15 is a timer). Both simple-card CPU DAI nodes must set
`system-clock-direction-out` so MCLK is configured as an output.

The kernel build remains independent of ESP-IDF. Firmware builds use the
ESP-IDF revision pinned by the `esp-hosted` submodule and its corresponding
toolchain.

## Boot console and settings TUI

The T-Deck Plus kernel command line sends boot messages to `tty0` (the LCD
framebuffer) and `ttyGS3` (USB serial). Do not add `quiet` if boot logs should be
visible. The `/etc/init.d/S99tdeck-console` hook adds a `tty1` login after the
startup scripts finish, lowers later printk noise, restores the saved settings,
and switches the LCD to that terminal. The root login can run `tdeckctl` for
Wi-Fi scan/connect/status, keyboard-backlight on/off/brightness, console font,
ALSA-card status, and system information.

The console font is changed at runtime with `/home/bin/consolefont`, which
applies the embedded kernel glyphs (VGA8x16, VGA8x8, 7x14, VGA6x11) through the
KDFONTOP ioctl; the VT resizes automatically (320x240: 40x15, 45x17, 53x21 and
40x30 characters). The default is 6x11 (53x21); pick another size with
`tdeckctl font <name>` or menu item 6, and the choice is saved under
`/home/tdeck/` and restored at boot. Note the classic KD_FONT_OP_SET expects
every glyph padded to a 32-byte stride. The root shell is bash with readline,
so SYM pressed alone (reported as Tab by the keyboard remap) completes command
and file names; this was verified on the board with the physical keys.

Keyboard backlight is controlled by the separate ESP32-C3 keyboard MCU over
I2C (`0x55`, command `0x01`, brightness 0–255); the kernel exposes it at
`/sys/bus/i2c/devices/0-0055/keyboard_backlight`. The TUI saves the selected
level under `/home/tdeck/` and restores it during boot. This depends on keyboard
MCU firmware that supports the backlight I2C command.

The touchscreen coordinate transform and ST7789 initialization are based on
LilyGO/Zephyr board data and still need confirmation on the actual hardware.
Symbol mapping assumes a US keymap. The keyboard driver probes the LilyGO
firmware's raw key-matrix mode at probe() time (command 0x03 reads five column
bitmaps, 0x04 returns to key mode); when the protocol is unavailable it falls
back to ASCII character polling and the two remaps are inactive. With raw mode,
holding Mic reports LEFTCTRL (SYM+Mic still types 0 because Ctrl is suppressed
while SYM is held), and a standalone SYM press reports Tab one poll cycle
(10 ms) after release. The first kernel build kept counting an empty key-mode
read (0x00) as a pending character, so the SYM tap never fired; the fix (treat
0x00 as "no character") is in the shipped kernel and confirmed with `evpeek` on
the board (sym-alone -> KEY_TAB code=15, mic -> LEFTCTRL code=29). Note: a
`WARNING: net/wireless/core.h:230` from the esp-hosted RX workqueue
(`ESP_IF_RX_WORK_QUEUE`) shows up in dmesg shortly after boot; it is a Wi-Fi
stack warning, non-fatal, and unrelated to input or the console. On the connected board, the framebuffer exposed an I2S
reset failure; after correcting reset, DRAM alias, IRQ, and MCLK direction, both
ALSA cards register. The current rootfs does not include `aplay`/`arecord`, so
PCM playback and capture still need a user-space test tool.

htop and fastfetch run from `/home/bin`; their wrappers set `TERM=linux`, and
the htop wrapper also sets `LD_LIBRARY_PATH=/home/lib` for its private
`libncurses.so.6`. Both are cross-compiled against the rootfs uClibc 1.0.48.
htop links `fork-compat.c` statically because the NOMMU FDPIC loader cannot
resolve `fork` from a `libfork.so.0` copy under `/home/lib` (LD_PRELOAD of that
stub segfaults). The process is named `htop.bin`, so stop it with
`killall htop.bin`; `killall htop` does not match. The board's ~7.6 MiB RAM is
the practical ceiling: while htop renders, NOMMU memory pressure can make a
64 KiB contiguous allocation fail until it exits. htop was verified on the real
LCD (`framebuffer-htop-realscreen.png` in the keymap console-apps package).

## Build

From Windows PowerShell:

```powershell
wsl -d Ubuntu -u builder -- bash /mnt/c/Users/mizuk/esp32s3-linux/build-scripts/wsl-run-t-deck-plus.sh
```

This builds in a disposable WSL worktree, leaving the main kernel tree and its
existing generated files untouched. For a quicker DTS/driver compile check
without producing a kernel image, run `build-scripts\wsl-check-t-deck-plus.sh`.
The output is `kernel-work\out\xipImage-t-deck-plus`; the build checks that the
kernel fits the existing 4 MiB `linux` partition. To test on hardware,
write only that kernel partition using the existing kernel-test workflow after
selecting the correct serial port and making a backup. Do not use the full-image
flasher for this board bring-up; it also rewrites `/etc` and `/home`.

## Files

- `kernel-work\overlay\arch\xtensa\boot\dts\esp32s3-t-deck-plus.dts` — board wiring and bootargs
- `kernel-work\overlay\drivers\input\keyboard\tdeck-keyboard.c` — I2C keyboard input driver
- `kernel-work\config\t-deck-plus.config` — kernel feature profile
- `tools\tdeckctl.sh` ? on-board TUI settings (Wi-Fi, backlight, audio, system info, console font)
- `tools\tdeck-console-init.sh` ? BusyBox init hook that adds the tty1 login and restores settings
- `tools\consolefont.c` ? KDFONTOP font switcher (VGA8x16/VGA8x8/7x14/VGA6x11 glyphs embedded)
- `tools\evpeek.c` ? input-event dumper used to validate the keyboard remap
- `backup\` ? verified 16 MiB ROM backups (do not overwrite)
- `secrets\` ? board root password and (optionally) SSH helper files
- `build-output\t-deck-plus-keymap-console-apps-20261116\` ? current kernel + console-apps package

The board reaches the outside world with a passphrase-less ed25519 key
(`~/.ssh/id_ed25519_sakura`) that is also installed on this PC as
`~/.ssh/id_ed25519_sakura`. The remote account is `my-dev` on
`www3414.sakura.ne.jp`. A `ssh sakura` alias is configured on the PC
(`~/.ssh/config`, with `User my-dev`) and emulated on the board by the
`/home/bin/ssh` wrapper (Dropbear's dbclient does not read `~/.ssh/config`;
the wrapper expands `ssh sakura` to `my-dev@www3414.sakura.ne.jp`). The server's
`~/.ssh/authorized_keys` holds exactly one entry for this key and its host
keys are pinned in `/home/root/.ssh/known_hosts` on the board. Because the
Sakura shell is interactive-only, `ssh sakura` opens a login shell on both
sides; the board's outbound SSH needs Wi-Fi to be working. End-to-end
verification on the board succeeded: `ptyrun` (a small PTY allocator) ran
`ssh sakura` and captured the remote prompt `[my-dev@www3414 ~]$`. Note that
this dbclient build mis-parses the OpenSSH-format ed25519 key ("String too
long"), so the key is kept on the board in Dropbear native format
(`id_ed25519_sakura_db`, produced with `dropbearconvert`); the PC keeps
the OpenSSH-format original.
- `build-scripts\wsl-run-t-deck-plus.sh` — build entry point
- `build-scripts\wsl-check-t-deck-plus.sh` — isolated device-tree and driver compile check
- `build-scripts\wsl-htop-static-fork.sh` — rebuilds htop with fork-compat linked in statically
- `build-scripts\wsl-consolefont-build.sh` — builds the consolefont tool (glyphs generated from the kernel's lib/fonts)
- `build-output\t-deck-plus-keymap-console-apps-20261116\` — keymap kernel and console-apps package: flash plan, checksums, serial logs, and the on-screen htop/font captures
- `patches/03-audio-dma-reservation.patch` — firmware reservation of the SRAM page after the vector page (apply with `apply-local-changes.sh` before rebuilding `network_adapter`)

## Build

From Windows PowerShell:"
