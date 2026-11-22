#!/bin/bash
cd ~/esp32s3/out
echo "=== my symbols present in System.map-amoled ==="
grep -E " (amoled_fb_probe|amoled_fb_driver|amoled_send_rect|fbcon_init|do_fbcon_takeover|vt_console_print|esp32_spi_prepare_transfer|register_framebuffer)$" System.map-amoled
echo "=== section boundaries: baseline vs amoled ==="
for n in baseline amoled; do
  echo "-- $n"
  grep -E " (_stext|_etext|__start_rodata|__end_rodata|_sdata|_edata|__init_begin|__init_end|__bss_start|__bss_stop|_end)$" System.map-$n | awk '{printf "%s %s  ", $3, $1} END {print ""}'
done
echo "=== builtin DTB name and the display node in the kernel image ==="
grep -E "BUILTIN_DTB_NAME" config-amoled
strings -a xipImage-amoled | grep -m3 -E "amoled-1.43-co5300|Waveshare ESP32-S3-Touch-AMOLED|console=tty0"