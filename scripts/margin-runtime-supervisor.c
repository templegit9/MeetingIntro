/* Own exactly one engine process group; exit when MeetingIntro exits or crashes. */
#include <signal.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>
#include <stdlib.h>
static volatile sig_atomic_t stopping = 0;
static void stop(int sig) { (void)sig; stopping = 1; }
int main(int argc, char **argv) {
    if (argc != 2 || argv[1][0] != '/') return 64;
    pid_t owner = getppid();
    if (owner <= 1) return 70;
    signal(SIGTERM, stop); signal(SIGINT, stop); signal(SIGHUP, stop);
    pid_t child = fork();
    if (child < 0) return 71;
    if (child == 0) {
        setpgid(0, 0);
        signal(SIGTERM, SIG_DFL); signal(SIGINT, SIG_DFL); signal(SIGHUP, SIG_DFL);
        execl(argv[1], argv[1], "serve", (char *)0);
        _exit(72);
    }
    setpgid(child, child);
    int status = 0;
    while (!stopping && getppid() == owner) {
        if (waitpid(child, &status, WNOHANG) == child) {
            kill(-child, SIGTERM);
            return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
        }
        usleep(200000);
    }
    kill(-child, SIGTERM);
    for (int i=0; i<25; i++) {
        if (waitpid(child, &status, WNOHANG) == child) return 0;
        usleep(200000);
    }
    kill(-child, SIGKILL); waitpid(child, &status, 0); return 0;
}
