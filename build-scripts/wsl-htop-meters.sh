#!/usr/bin/env bash
# Meter names htop accepts in column_meters_N, and what SysArchMeter prints.
cd "$HOME/esp32s3/htop/src/htop-3.5.3" || exit 1
echo "--- meter class names ---"
grep -hE '^\s*\.name = "|^\s*\.uiName = "|^\s*\.caption = "' SysArchMeter.c HostnameMeter.c UptimeMeter.c LoadAverageMeter.c TasksMeter.c MemoryMeter.c SwapMeter.c CPUMeter.c | sed 's/^\s*//' | tr '\n' ' '
echo
echo "--- SysArchMeter body ---"
sed -n '/updateValues/,/^}/p' SysArchMeter.c | head -30
echo "--- header_layout / column_meters parsing ---"
grep -nE 'column_meters|column_meter_modes|left_meters' Settings.c | head
