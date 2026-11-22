#!/bin/sh
# BusyBox init hook: move the completed boot from the framebuffer console to tty1.
case "${1:-}" in
start)
	line='tty1::respawn:/sbin/getty -L tty1 0 linux'
	if ! grep -qxF "$line" /etc/inittab; then
		printf '%s\n' "$line" >> /etc/inittab
	fi
	# Restore settings selected with tdeckctl; the keyboard MCU resets its PWM
	# state when the board reboots.
	if [ -r /home/tdeck/keyboard-backlight-default ]; then
		level=$(cat /home/tdeck/keyboard-backlight-default 2>/dev/null)
		case $level in ''|*[!0-9]*) ;; *)
			[ "$level" -ge 31 ] && [ "$level" -le 255 ] &&
				printf '%s\n' "$level" > /sys/bus/i2c/devices/0-0055/keyboard_backlight_default
			;;
		esac
	fi
	if [ -r /home/tdeck/keyboard-backlight ]; then
		level=$(cat /home/tdeck/keyboard-backlight 2>/dev/null)
		case $level in ''|*[!0-9]*) ;; *)
			[ "$level" -le 255 ] &&
				printf '%s\n' "$level" > /sys/bus/i2c/devices/0-0055/keyboard_backlight
			;;
		esac
	fi
	# Restore the console font selected with tdeckctl; applies to the
	# foreground VT (tty1 on the LCD).
	if [ -x /home/bin/consolefont ] && [ -r /home/tdeck/console-font ]; then
		font=$(cat /home/tdeck/console-font 2>/dev/null)
		case $font in
			8x16|8x8|7x14|6x11) /home/bin/consolefont "$font" >/dev/null 2>&1 ;;
		esac
	fi
	# Keep boot-time printk visible, then leave only warnings/errors on the terminal.
	dmesg -n 4 2>/dev/null || :
	# BusyBox init read the cramfs inittab before /etc was mounted; reload the JFFS2 copy.
	kill -HUP 1
	sleep 1
	chvt 1 2>/dev/null || :
	;;
esac
exit 0
