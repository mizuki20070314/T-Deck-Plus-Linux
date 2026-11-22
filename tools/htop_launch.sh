#!/bin/sh
# Run htop full screen on the AMOLED console (tty1). Runs on the board, installed as
# /home/bin/htop-launch by tools\htop_autostart.ps1 and started by init from /etc/inittab:
#   tty1::respawn:/home/bin/htop-launch
# init has already made tty1 our stdin, stdout, stderr and controlling terminal.
#
# When htop ends (killed, crashed, or q) wait a little so that a crash loop cannot eat the
# only CPU, then exit; init starts this script again (3 s later, 10 s if htop did not even
# run for 5 s).
HTOP=/home/bin/htop
# Minutes until the console blanks, 0 = never. An AMOLED that shows the same picture for
# months burns in, so use e.g. 10 if the display stays on all the time. The board has no
# keyboard to wake it: do that over ssh with  printf '\033[9;10]' > /dev/tty1
BLANK_MIN=0
export TERM=linux HOME=/home/root
export HTOPRC=/home/bin/htoprc      # not the htoprc that an htop run from an SSH session uses

if [ ! -x "$HTOP" ]; then
	echo "htop-launch: $HTOP is missing"
	sleep 10
	exit 1
fi

printf '\033[9;%d]' "$BLANK_MIN"
printf '\033[2J\033[H'      # clear the screen
read -r t0 _ < /proc/uptime
"$HTOP"
read -r t1 _ < /proc/uptime
# An htop that stops within seconds did not start, typically because the RAM has no free
# block big enough for it any more (HTOP.md). Wait longer then, so that the retries do not
# flood the console with the kernel's memory report.
if [ "${t1%.*}" -lt $(( ${t0%.*} + 5 )) ]; then sleep 10; else sleep 3; fi
