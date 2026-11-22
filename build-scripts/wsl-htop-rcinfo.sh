#!/usr/bin/env bash
# What does htop 3.5.3 accept in htoprc?
cd "$HOME/esp32s3/htop/src/htop-3.5.3" || exit 1
echo "--- keys read by Settings.c ---"
grep -oE 'String_eq\(option\[0\], "[a-z_0-9.]+"\)' Settings.c | sed -E 's/.*"([^"]+)".*/\1/' | tr '\n' ' '
echo
echo "--- header layouts ---"
grep -nE '\{ *\.(name|description)|"(one|two|three|four)_' HeaderLayout.h | head -30
echo "--- screen: lines ---"
grep -nE '"screen:|"\.sort_key|"\.tree|sort_direction|screen_tabs|hide_function_bar' Settings.c | head -30
echo "--- default Main screen fields ---"
grep -nE 'PID|Command' Settings.c | head -10
echo "--- ProcessField names (Platform / linux) ---"
grep -nE '"(PID|STATE|PERCENT_CPU|PERCENT_MEM|TIME|Command|COMM|USER|M_RESIDENT|PRIORITY|NICE)"' ProcessTable.c Process.c linux/LinuxProcess.c 2>/dev/null | head -20
