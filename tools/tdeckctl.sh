#!/bin/sh
# T-Deck Plus terminal settings TUI. Run as root on tty1 with `tdeckctl`.

PATH=/home/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

KBD_SYSFS=/sys/bus/i2c/devices/0-0055
KBD_LEVEL=$KBD_SYSFS/keyboard_backlight
KBD_DEFAULT=$KBD_SYSFS/keyboard_backlight_default
STATE_DIR=/home/tdeck

clear_screen() { printf '\033[2J\033[H'; }
pause() { printf '\nPress Enter to continue...'; IFS= read -r _ || :; }

valid_level() {
	case $1 in
		''|*[!0-9]*) return 1 ;;
	esac
	[ "${#1}" -le 3 ] && [ "$1" -le 255 ]
}

save_level() {
	name=$1
	value=$2
	mkdir -p "$STATE_DIR" || return 1
	chmod 700 "$STATE_DIR" 2>/dev/null || :
	printf '%s\n' "$value" > "$STATE_DIR/$name" || return 1
	chmod 600 "$STATE_DIR/$name" 2>/dev/null || :
}

set_backlight() {
	level=$1
	if ! valid_level "$level"; then
		echo 'Brightness must be a number from 0 to 255.'
		return 1
	fi
	if [ ! -w "$KBD_LEVEL" ]; then
		echo 'Keyboard backlight control is unavailable; install the T-Deck kernel update.'
		return 1
	fi
	if ! printf '%s\n' "$level" > "$KBD_LEVEL"; then
		echo 'The keyboard controller did not accept the backlight command.'
		return 1
	fi
	if ! save_level keyboard-backlight "$level"; then
		echo 'Backlight changed, but the setting could not be saved.'
		return 1
	fi
	printf 'Keyboard backlight set to %s/255.\n' "$level"
}

set_default_backlight() {
	level=$1
	if ! valid_level "$level" || [ "$level" -lt 31 ]; then
		echo 'Alt+B default brightness must be from 31 to 255.'
		return 1
	fi
	if [ ! -w "$KBD_DEFAULT" ]; then
		echo 'Keyboard backlight default control is unavailable.'
		return 1
	fi
	if ! printf '%s\n' "$level" > "$KBD_DEFAULT"; then
		echo 'The keyboard controller did not accept the default brightness.'
		return 1
	fi
	if ! save_level keyboard-backlight-default "$level"; then
		echo 'Default brightness changed, but the setting could not be saved.'
		return 1
	fi
	printf 'Alt+B default brightness set to %s/255.\n' "$level"
}

valid_font() {
	case $1 in
		8x16|8x8|7x14|6x11) return 0 ;;
	esac
	return 1
}

set_font() {
	font=$1
	if ! valid_font "$font"; then
		echo 'Font must be one of: 8x16, 8x8, 7x14, 6x11.'
		return 1
	fi
	if ! command -v consolefont >/dev/null 2>&1; then
		echo 'consolefont is not installed in /home/bin.'
		return 1
	fi
	if ! consolefont "$font"; then
		echo 'The console font change failed.'
		return 1
	fi
	if ! save_level console-font "$font"; then
		echo 'Font changed, but the setting could not be saved.'
		return 1
	fi
	printf 'Console font set to %s.\n' "$font"
}

show_status() {
	printf '=== Wi-Fi ===\n'
	/usr/bin/wifi status 2>&1
	printf '\n=== Keyboard backlight ===\n'
	if [ -r "$KBD_LEVEL" ]; then
		printf 'Last Linux setting: %s/255\n' "$(cat "$KBD_LEVEL" 2>/dev/null)"
		printf 'Alt+B default: %s/255\n' "$(cat "$KBD_DEFAULT" 2>/dev/null)"
	else
		echo 'Control unavailable.'
	fi
	printf '\n=== ALSA ===\n'
	cat /proc/asound/cards /proc/asound/pcm 2>&1
	if ! command -v aplay >/dev/null 2>&1 || ! command -v arecord >/dev/null 2>&1; then
		echo 'aplay/arecord are not installed in this rootfs.'
	fi
	printf '\n=== Display ===\n'
	cat /sys/class/graphics/fb0/virtual_size 2>&1 || :
}

backlight_menu() {
	while :; do
		clear_screen
		printf 'T-Deck Plus / Keyboard Backlight\n\n'
		if [ -r "$KBD_LEVEL" ]; then
			printf 'Last Linux setting: %s/255\n' "$(cat "$KBD_LEVEL" 2>/dev/null)"
			printf 'Alt+B default: %s/255\n' "$(cat "$KBD_DEFAULT" 2>/dev/null)"
		else
			printf 'Control: unavailable\n'
		fi
		printf '\n1. On (127)\n2. Off\n3. Set brightness (0-255)\n4. Set Alt+B default (31-255)\n0. Back\n\nSelect: '
		IFS= read -r choice || return
		case $choice in
			1) set_backlight 127; pause ;;
			2) set_backlight 0; pause ;;
			3)
				printf 'Brightness 0-255: '
				IFS= read -r level || return
				set_backlight "$level"
				pause
				;;
			4)
				printf 'Alt+B default 31-255: '
				IFS= read -r level || return
				set_default_backlight "$level"
				pause
				;;
			0|q|Q) return ;;
			*) echo 'Invalid selection.'; pause ;;
		esac
	done
}

wifi_menu() {
	while :; do
		clear_screen
		printf 'T-Deck Plus / Wi-Fi\n\n'
		/usr/bin/wifi status 2>&1
		printf '\n1. Scan and connect\n2. Scan only\n3. Disconnect\n0. Back\n\nSelect: '
		IFS= read -r choice || return
		case $choice in
			1) /usr/bin/wifi 2>&1; pause ;;
			2) /usr/bin/wifi scan 2>&1; pause ;;
			3) /usr/bin/wifi disconnect 2>&1; pause ;;
			0|q|Q) return ;;
			*) echo 'Invalid selection.'; pause ;;
		esac
	done
}

font_menu() {
	while :; do
		clear_screen
		printf 'T-Deck Plus / Console Font\n\n'
		printf 'Saved font: %s\n' "$(cat "$STATE_DIR/console-font" 2>/dev/null || echo 'not set')"
		printf 'Terminal now: %s\n' "$(stty size < /dev/tty0 2>/dev/null | awk '{ print $2 " columns x " $1 " rows" }')"
		printf '\n1. 8x16  large      (40x15)\n2. 7x14  small      (45x17)\n3. 6x11  smaller    (53x21)\n4. 8x8   smallest   (40x30)\n0. Back\n\nSelect: '
		IFS= read -r choice || return
		case $choice in
			1) set_font 8x16; pause ;;
			2) set_font 7x14; pause ;;
			3) set_font 6x11; pause ;;
			4) set_font 8x8; pause ;;
			0|q|Q) return ;;
			*) echo 'Invalid selection.'; pause ;;
		esac
	done
}

system_info() {
	if [ -x /home/bin/fastfetch ]; then
		TERM=linux /home/bin/fastfetch 2>&1
	else
		/usr/bin/espctl system info 2>&1 || uname -a
		printf '\nMemory available: '
		awk '/MemAvailable:/ { printf "%s kB\n", $2 }' /proc/meminfo 2>/dev/null
		printf 'Uptime: '
		cut -d' ' -f1 /proc/uptime 2>/dev/null
	fi
}

case ${1-} in
	backlight)
		case ${2-} in
			on) set_backlight 127 ;;
			off) set_backlight 0 ;;
			*) set_backlight "${2-}" ;;
		esac
		exit $?
		;;
	backlight-default)
		set_default_backlight "${2-}"
		exit $?
		;;
	font)
		set_font "${2-}"
		exit $?
		;;
	wifi)
		shift
		exec /usr/bin/wifi "$@"
		;;
	status)
		show_status
		exit 0
		;;
	info)
		system_info
		exit 0
		;;
esac

while :; do
	clear_screen
	printf 'T-Deck Plus Settings\n\n'
	printf '1. Wi-Fi scan / connect\n'
	printf '2. Wi-Fi status\n'
	printf '3. Keyboard backlight\n'
	printf '4. Audio devices\n'
	printf '5. System information\n'
	printf '6. Console font\n'
	printf '0. Exit\n\nSelect: '
	IFS= read -r choice || exit 0
	case $choice in
		1) wifi_menu ;;
		2) clear_screen; /usr/bin/wifi status 2>&1; pause ;;
		3) backlight_menu ;;
		4) clear_screen; cat /proc/asound/cards /proc/asound/pcm 2>&1; pause ;;
		5) clear_screen; system_info; pause ;;
		6) font_menu ;;
		0|q|Q) clear_screen; exit 0 ;;
		*) echo 'Invalid selection.'; pause ;;
	esac
done
