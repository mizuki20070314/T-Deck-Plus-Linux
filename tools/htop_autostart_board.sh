#!/bin/sh
# Turn the boot-time htop on or off. Runs on the board (tools\htop_autostart.ps1 copies it to
# /tmp, together with /tmp/htop_launch.sh and /tmp/htoprc).
#   sh /tmp/htop_autostart_board.sh enable | disable | status
#
# The whole mechanism is one line in /etc/inittab (jffs2, so it survives reboots):
#   tty1::respawn:/home/bin/htop-launch
# init reads that file only when S47usbconsole sends it a SIGHUP (the cramfs copy is all it
# sees at first), so the line is picked up at boot by the poke that already starts the ttyGS3
# getty, and right now by `kill -HUP 1`.

INITTAB=/etc/inittab
SAVED=/etc/inittab.before-htop
LINE='tty1::respawn:/home/bin/htop-launch'
NOTE='# htop on the AMOLED console: tools\htop_autostart.ps1 -Disable takes it out again'

# install_file FROM TO MODE: copy beside the target, then rename. A running file can be
# replaced that way, and a half-written one is never executed.
install_file() {
	cp "$1" "$2.new" && chmod "$3" "$2.new" && mv "$2.new" "$2"
}

case "$1" in
enable)
	mkdir -p /home/bin
	[ -f /tmp/htop_launch.sh ] && install_file /tmp/htop_launch.sh /home/bin/htop-launch 755
	[ -f /tmp/htoprc ] && install_file /tmp/htoprc /home/bin/htoprc 644
	[ -x /home/bin/htop ] || { echo 'enable: /home/bin/htop is missing (htop_show.ps1 -Install puts it there)'; exit 1; }
	[ -x /home/bin/htop-launch ] || { echo 'enable: /home/bin/htop-launch is missing'; exit 1; }
	[ -f "$SAVED" ] || cp -p "$INITTAB" "$SAVED"
	if grep -qx "$LINE" "$INITTAB"; then
		echo "$INITTAB already has the htop line"
	else
		# The new inittab is built beside the old one and renamed over it. The line goes
		# right after the ttyGS3 getty (at the end if there is none).
		added=
		while IFS= read -r l; do
			printf '%s\n' "$l"
			case $l in
			ttyGS3::respawn:*) printf '%s\n%s\n' "$NOTE" "$LINE"; added=1 ;;
			esac
		done < "$INITTAB" > "$INITTAB.new"
		[ -n "$added" ] || printf '%s\n%s\n' "$NOTE" "$LINE" >> "$INITTAB.new"
		# Take our two lines out again: what is left must be the old inittab, byte for byte.
		if ! grep -vxF -e "$NOTE" -e "$LINE" "$INITTAB.new" | cmp -s - "$INITTAB"; then
			echo 'enable: the new inittab differs from the old one in more than the htop lines; not installed'
			rm -f "$INITTAB.new"
			exit 1
		fi
		mv "$INITTAB.new" "$INITTAB"
		echo "added to $INITTAB (the old one is in $SAVED):"
		grep -n -B1 -x "$LINE" "$INITTAB"
	fi
	sync
	kill -HUP 1             # init rereads inittab and starts htop-launch on tty1
	;;
disable)
	if grep -qx "$LINE" "$INITTAB"; then
		grep -vxF -e "$NOTE" -e "$LINE" "$INITTAB" > "$INITTAB.new" && mv "$INITTAB.new" "$INITTAB"
		echo "removed the htop line from $INITTAB"
	else
		echo "$INITTAB has no htop line"
	fi
	sync
	kill -HUP 1
	killall htop 2>/dev/null    # the launcher then ends, and init no longer restarts it
	;;
status)
	if grep -qx "$LINE" "$INITTAB"; then echo "autostart: ON  ($LINE in $INITTAB)"; else echo "autostart: off"; fi
	ls -l /home/bin/htop /home/bin/htop-launch /home/bin/htoprc 2>&1
	pid=$(pidof htop) && echo "htop is running (pid $pid)" || echo "htop is not running"
	;;
*)
	echo "usage: sh $0 enable|disable|status" >&2
	exit 2
	;;
esac
