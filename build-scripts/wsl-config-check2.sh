#!/bin/bash
echo "=== options ENABLED by the AMOLED config that the baseline does not have ==="
diff <(grep -E '^CONFIG_' /tmp/kout-base/.config | sort) <(grep -E '^CONFIG_' /tmp/kout-amoled/.config | sort) | grep -E '^[<>]' | grep -v -E 'CONFIG_(CC_|GCC|CLANG|LD_|AS_|TOOLS|PAHOLE|RUSTC|BINDGEN|HAVE_.*COMPILER)'
echo "=== input-related symbols that are y ==="
grep -E '^CONFIG_(INPUT|KEYBOARD|MOUSE|SERIO|HID|TOUCHSCREEN|JOYSTICK|TABLET|FONT|FB_|VT|CONSOLE|DUMMY|LOGO|FRAMEBUFFER|VGA|BACKLIGHT|LCD|DRM|VIDEO|HW_CONSOLE)' /tmp/kout-amoled/.config