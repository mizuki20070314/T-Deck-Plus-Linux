/* evpeek - print EV_KEY events from an input device in human-readable form.
 *
 * Usage: evpeek <device> [max-events]
 *
 * Blocks reading events and prints one line per event:
 *     <time_ms> code=<code> value=<0|1|2>
 * Exits after max-events (default 64) events, or on SIGINT.
 */
#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv)
{
	unsigned long limit = 64, seen = 0;

	if (argc < 2) {
		fprintf(stderr, "usage: evpeek <device> [max-events]\n");
		return 2;
	}
	if (argc > 2)
		limit = strtoul(argv[2], NULL, 0);

	int fd = open(argv[1], O_RDONLY);
	if (fd < 0) {
		perror(argv[1]);
		return 1;
	}
	printf("evpeek: opened %s, waiting for events\n", argv[1]);
	fflush(stdout);

	struct input_event ev;
	while (seen < limit) {
		int ret = read(fd, &ev, sizeof(ev));
		if (ret == (int)sizeof(ev)) {
			if (ev.type != EV_KEY)
				continue;
			printf("t=%lu.%06lu code=%u value=%d\n",
			       (unsigned long)ev.time.tv_sec,
			       (unsigned long)ev.time.tv_usec, ev.code, ev.value);
			fflush(stdout);
			seen++;
			continue;
		}
		if (ret < 0)
			printf("evpeek: read error: %s (ret=%d)\n",
			       strerror(errno), ret);
		else
			printf("evpeek: short read: ret=%d\n", ret);
		fflush(stdout);
		break;
	}
	printf("evpeek: exiting after %lu events\n", seen);
	fflush(stdout);
	return 0;
}
