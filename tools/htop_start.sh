#!/bin/sh
# Show htop full screen on the AMOLED console (tty1). Runs on the board.
#   sh /tmp/htop_start.sh        (copied there by tools\htop_show.ps1, together with /tmp/htoprc)
# Stop it again with: killall htop   (with the boot-time autostart on, init starts it again)
if grep -qx 'tty1::respawn:/home/bin/screend' /etc/inittab; then
	# The screen service (tools\screen_install.ps1) owns tty1: give it the new config, ask it for
	# htop, and let it restart htop.
	[ -f /tmp/htoprc ] && cp /tmp/htoprc /home/bin/htoprc.new && mv /home/bin/htoprc.new /home/bin/htoprc
	/home/bin/screend ctl mode htop
	/home/bin/screend ctl refresh
	sleep 9
	pidof htop && echo "htop is running (started by screend)" || echo "htop is NOT running"
	exit 0
fi
if grep -qx 'tty1::respawn:/home/bin/htop-launch' /etc/inittab; then
	# Autostart is on, so init owns tty1: hand it the new config and let it restart htop
	# (it runs htop-launch again 3 s after htop ends). A second htop here would fight it.
	[ -f /tmp/htoprc ] && cp /tmp/htoprc /home/bin/htoprc.new && mv /home/bin/htoprc.new /home/bin/htoprc
	killall htop 2>/dev/null
	sleep 6
	pidof htop && echo "htop is running (started by init)" || echo "htop is NOT running"
	exit 0
fi
killall htop 2>/dev/null
sleep 1
mkdir -p /home/root/.config/htop
[ -f /tmp/htoprc ] && cp /tmp/htoprc /home/root/.config/htop/htoprc
printf '\033[9;0]' > /dev/tty1        # never blank the console (AMOLED: lower the brightness instead)
printf '\033[2J\033[H' > /dev/tty1     # clear the screen
# New session with tty1 as its controlling terminal; the console is 41x20 characters.
setsid -c env TERM=linux HOME=/home/root /home/bin/htop < /dev/tty1 > /dev/tty1 2>&1 &
sleep 3
pidof htop && echo "htop is running" || echo "htop is NOT running"
