#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <sys/wait.h>
#include <termios.h>
#include <time.h>
#include <unistd.h>

/* ptyrun - run a command on a pseudo-terminal, capture output to a file.
 *
 * Usage: ptyrun <logfile> <command> [args...]
 */
int main(int argc, char **argv)
{
    if (argc < 3) {
        fprintf(stderr, "usage: ptyrun <logfile> <command> [args...]\n");
        return 2;
    }
    const char *logfile = argv[1];
    char **cmd = &argv[2];

    int master = posix_openpt(O_RDWR | O_NOCTTY);
    if (master < 0) { perror("posix_openpt"); return 1; }
    if (grantpt(master) < 0) { perror("grantpt"); return 1; }
    if (unlockpt(master) < 0) { perror("unlockpt"); return 1; }
    char *slave_name = ptsname(master);
    if (!slave_name) { perror("ptsname"); return 1; }

    pid_t pid = vfork();
    if (pid < 0) { perror("fork"); return 1; }
    if (pid == 0) {
        setsid();
        int slave = open(slave_name, O_RDWR);
        if (slave < 0) { perror("open slave"); _exit(127); }
        ioctl(slave, TIOCSCTTY, 0);
        dup2(slave, 0);
        dup2(slave, 1);
        dup2(slave, 2);
        if (slave > 2) close(slave);
        close(master);
        execvp(cmd[0], cmd);
        perror("execvp");
        _exit(127);
    }

    FILE *lf = fopen(logfile, "w");
    if (!lf) { perror(logfile); }
    char buf[4096];
    int alive = 1;
    time_t start = time(NULL);
    while (alive && (time(NULL) - start) < 8) {
        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(master, &rfds);
        struct timeval tv = { 0, 200000 };
        int r = select(master + 1, &rfds, NULL, NULL, &tv);
        if (r > 0 && FD_ISSET(master, &rfds)) {
            ssize_t n = read(master, buf, sizeof(buf));
            if (n > 0) {
                if (lf) { fwrite(buf, 1, n, lf); fflush(lf); }
            } else if (n == 0) {
                alive = 0;
            } else if (errno != EINTR) {
                alive = 0;
            }
        }
        int st;
        pid_t w = waitpid(pid, &st, WNOHANG);
        if (w == pid) { alive = 0; }
    }
    close(master);
    int status = 0;
    for (int i = 0; i < 30; i++) {
        pid_t w = waitpid(pid, &status, WNOHANG);
        if (w == pid) break;
        usleep(100000);
    }
    pid_t w = waitpid(pid, &status, WNOHANG);
    if (w == pid) {
        if (WIFEXITED(status))
            printf("EXITED rc=%d\n", WEXITSTATUS(status));
        else
            printf("EXITED signal=%d\n", WTERMSIG(status));
    } else {
        printf("STILL_RUNNING\n");
        kill(pid, SIGTERM);
        waitpid(pid, &status, 0);
    }
    if (lf) fclose(lf);
    return 0;
}